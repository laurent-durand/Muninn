# src/julia_layer/analysis.jl
# Muninn mathematical analysis — Julia.
# Julia's JIT and linear algebra stdlib make it ideal for heavier
# metric math: anomaly detection via PCA, forecast with Holt-Winters,
# and changepoint detection.

module MuninnAnalysis

using Statistics
using LinearAlgebra
using JSON3

export analyse_window, holt_winters, detect_changepoints, pca_anomaly

# ─── Rolling window structure ─────────────────────────────────────────────────

mutable struct MetricWindow
    cpu_pct  :: Vector{Float64}
    mem_pct  :: Vector{Float64}
    load_one :: Vector{Float64}
    ts_ms    :: Vector{Int64}
    capacity :: Int

    MetricWindow(n::Int) = new(
        Float64[], Float64[], Float64[], Int64[], n
    )
end

function push!(w::MetricWindow, snap::Dict)
    function pushval!(v, key, default=0.0)
        push!(v, get(snap, key, default))
        length(v) > w.capacity && deleteat!(v, 1)
    end
    pushval!(w.cpu_pct,  :cpu_pct)
    pushval!(w.load_one, get(get(snap, :load, Dict()), :one, 0.0))
    mem = get(snap, :mem, Dict())
    tot = get(mem, :total_kb, 0)
    avl = get(mem, :available_kb, 0)
    mp  = tot > 0 ? (tot - avl) / tot * 100.0 : 0.0
    push!(w.mem_pct, mp)
    length(w.mem_pct) > w.capacity && deleteat!(w.mem_pct, 1)
    push!(w.ts_ms, get(snap, :timestamp_ms, 0))
    length(w.ts_ms) > w.capacity && deleteat!(w.ts_ms, 1)
end

# ─── Holt-Winters exponential smoothing (additive, no seasonality) ────────────

struct HoltWinters
    α :: Float64   # level smoothing
    β :: Float64   # trend smoothing
    level  :: Vector{Float64}
    trend  :: Vector{Float64}
end

function HoltWinters(xs::Vector{Float64}; α=0.3, β=0.1)
    isempty(xs) && return HoltWinters(α, β, Float64[], Float64[])
    l = [xs[1]]
    t = [length(xs) > 1 ? xs[2] - xs[1] : 0.0]
    for i in 2:length(xs)
        l_prev, t_prev = l[end], t[end]
        l_new = α * xs[i] + (1-α) * (l_prev + t_prev)
        t_new = β * (l_new - l_prev) + (1-β) * t_prev
        push!(l, l_new); push!(t, t_new)
    end
    HoltWinters(α, β, l, t)
end

holt_winters(xs::Vector{Float64}, h::Int=5) = begin
    hw = HoltWinters(xs)
    isempty(hw.level) && return fill(0.0, h)
    l, t = hw.level[end], hw.trend[end]
    [l + i*t for i in 1:h]
end

# ─── Changepoint detection (CUSUM) ────────────────────────────────────────────

function detect_changepoints(xs::Vector{Float64}; k=0.5, h=5.0)
    isempty(xs) && return Int[]
    μ = mean(xs)
    σ = std(xs)
    σ < 1e-9 && return Int[]

    cp = Int[]
    s_hi = s_lo = 0.0
    for (i, x) in enumerate(xs)
        z      = (x - μ) / σ
        s_hi   = max(0, s_hi + z - k)
        s_lo   = max(0, s_lo - z - k)
        (s_hi > h || s_lo > h) && (push!(cp, i); s_hi = s_lo = 0.0)
    end
    cp
end

# ─── PCA anomaly score ────────────────────────────────────────────────────────

function pca_anomaly(w::MetricWindow)::Float64
    length(w.cpu_pct) < 10 && return 0.0

    # Build feature matrix (n × 3)
    n  = min(length(w.cpu_pct), length(w.mem_pct), length(w.load_one))
    X  = hcat(w.cpu_pct[end-n+1:end],
               w.mem_pct[end-n+1:end],
               w.load_one[end-n+1:end])

    # Center
    μ_col = mean(X, dims=1)
    Xc    = X .- μ_col

    # SVD for PCA
    F   = svd(Xc)
    # Reconstruction error of the last point using top-1 component
    x_last = Xc[end, :]
    pc1    = F.V[:, 1]
    proj   = dot(x_last, pc1) * pc1
    norm(x_last - proj)
end

# ─── Window summary ───────────────────────────────────────────────────────────

function analyse_window(w::MetricWindow)::Dict
    isempty(w.cpu_pct) && return Dict(:error => "no data")

    cpu  = w.cpu_pct
    mem  = w.mem_pct
    load = w.load_one

    forecast_cpu = holt_winters(cpu, 5)
    changepoints = detect_changepoints(cpu)
    anomaly_z    = pca_anomaly(w)

    Dict(
        :type           => "analysis",
        :n              => length(cpu),
        :cpu_mean       => mean(cpu),
        :cpu_std        => std(cpu),
        :cpu_p50        => quantile(cpu, 0.5),
        :cpu_p90        => quantile(cpu, 0.9),
        :cpu_p99        => quantile(cpu, 0.99),
        :cpu_forecast_5s => forecast_cpu,
        :changepoints   => changepoints,
        :pca_anomaly_score => anomaly_z,
        :mem_mean       => mean(mem),
        :load_mean      => mean(load),
    )
end

# ─── Main I/O loop ────────────────────────────────────────────────────────────

function main()
    w = MetricWindow(300)   # 5-minute window at 1Hz

    for line in eachline(stdin)
        isempty(strip(line)) && continue
        snap = try JSON3.read(line, Dict{Symbol,Any})
               catch; continue end
        push!(w, snap)
        length(w.cpu_pct) % 30 == 0 || continue  # report every 30s
        report = analyse_window(w)
        println(JSON3.write(report))
        flush(stdout)
    end
end

end # module

MuninnAnalysis.main()
