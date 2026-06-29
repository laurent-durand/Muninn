// src/syscall/proctree.ha
// Muninn procfs interface — Hare.
// Walks /proc to build a snapshot of all running processes.
// Output: newline-delimited JSON on stdout.

use fmt;
use fs;
use io;
use os;
use os::exec;
use strconv;
use strings;
use time;
use bufio;

// Process entry mirroring proto ProcEntry
type proc_entry = struct {
	pid     : int,
	ppid    : int,
	name    : str,
	state   : str,
	utime   : u64,
	stime   : u64,
	rss_kb  : u64,
	vsz_kb  : u64,
	threads : int,
	nice    : int,
};

// Read /proc/<pid>/stat fields
fn read_stat(pid: int) (proc_entry | void) = {
	const path = fmt::asprintf("/proc/{}/stat", pid);
	defer free(path);

	const f = match (os::open(path)) {
	case let f: io::file => yield f;
	case => return void;
	};
	defer io::close(f)!;

	let buf = bufio::newreader(&f, bufio::dynamic);
	defer bufio::finish(&buf);

	const line = match (bufio::read_line(&buf)) {
	case let l: []u8 => yield strings::fromutf8(l)!;
	case => return void;
	};
	defer free(line);

	// format: pid (name) state ppid ... utime stime ... rss
	// field indices (0-based): 0=pid 1=name 2=state 3=ppid
	//   13=utime 14=stime 18=nice 19=nthreads 23=vsize 24=rss
	const rparen = match (strings::rindex(line, ')')) {
	case let i: size => yield i;
	case => return void;
	};

	const name_start = match (strings::index(line, '(')) {
	case let i: size => yield i + 1;
	case => return void;
	};
	const name = strings::sub(line, name_start, rparen);

	const rest  = strings::trimprefix(line[rparen + 2..], "");
	const fields = strings::splitall(rest, " ");
	defer strings::freeall(fields);

	if (len(fields) < 25) return void;

	fn fi(s: str) int = strconv::stoi(s) as int;
	fn fu(s: str) u64 = strconv::stou64(s) as u64;

	return proc_entry {
		pid     = pid,
		ppid    = fi(fields[1]),
		name    = strings::dup(name),
		state   = strings::dup(fields[0]),
		utime   = fu(fields[11]),
		stime   = fu(fields[12]),
		nice    = fi(fields[16]),
		threads = fi(fields[17]),
		vsz_kb  = fu(fields[20]) / 1024,
		rss_kb  = fu(fields[21]) * 4,    // pages → KiB (4K pages)
	};
};

// Emit a proc_entry as a JSON object
fn emit_entry(e: proc_entry) void = {
	fmt::printf(`{{"pid":{},"ppid":{},"name":{},"state":"{}","rss_kb":{},"vsz_kb":{},"threads":{},"nice":{}}}`,
		e.pid, e.ppid,
		fmt::format(`"{}"`, strings::replace(e.name, `"`, `\"`, -1)),
		e.state, e.rss_kb, e.vsz_kb, e.threads, e.nice,
	)!;
	free(e.name);
	free(e.state);
};

export fn main() void = {
	for (true) {
		const dir = match (os::open("/proc")) {
		case let d: fs::dir => yield d;
		case => break;
		};

		let entries: []proc_entry = [];
		defer {
			for (let i = 0z; i < len(entries); i += 1) {
				free(entries[i].name);
				free(entries[i].state);
			};
			free(entries);
		};

		for (true) {
			const dent = match (fs::next(dir)) {
			case let e: fs::dirent => yield e;
			case void => break;
			case fs::error => break;
			};
			const pid = match (strconv::stoi(dent.name)) {
			case let p: int => yield p;
			case => continue;
			};
			match (read_stat(pid)) {
			case let e: proc_entry => append(entries, e);
			case => void;
			};
		};
		fs::close(dir);

		// Sort by rss_kb descending
		for (let i = 0z; i < len(entries); i += 1) {
			for (let j = i + 1; j < len(entries); j += 1) {
				if (entries[j].rss_kb > entries[i].rss_kb) {
					const tmp  = entries[i];
					entries[i] = entries[j];
					entries[j] = tmp;
				};
			};
		};

		fmt::print(`{"type":"proctree","procs":[`)!;
		for (let i = 0z; i < len(entries); i += 1) {
			if (i > 0) fmt::print(",")!;
			emit_entry(entries[i]);
		};
		fmt::println("]}")!;

		time::sleep(1 * time::SECOND);
	};
};
