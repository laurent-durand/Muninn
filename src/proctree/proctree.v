// src/proctree/proctree.v
// Muninn process tree — V (Vlang).
// Reads /proc, builds a parent→children tree, emits JSON.

module main

import os
import json
import time
import strconv

struct ProcNode {
	pid      int
	ppid     int
	name     string
	state    string
	rss_kb   u64
	vsz_kb   u64
	threads  int
	children []int  [json: 'children']
}

fn parse_proc(pid int) ?ProcNode {
	stat_path := '/proc/${pid}/stat'
	stat_raw  := os.read_file(stat_path) or { return none }

	// Extract name between first '(' and last ')'
	lparen := stat_raw.index('(') or { return none }
	rparen := stat_raw.last_index(')') or { return none }
	name   := stat_raw[lparen + 1..rparen]
	rest   := stat_raw[rparen + 2..].split(' ')

	if rest.len < 25 { return none }

	return ProcNode{
		pid:     pid,
		ppid:    strconv.atoi(rest[1]) or { 0 },
		name:    name,
		state:   rest[0],
		threads: strconv.atoi(rest[17]) or { 0 },
		vsz_kb:  strconv.parse_uint(rest[20], 10, 64) or { u64(0) } / 1024,
		rss_kb:  strconv.parse_uint(rest[21], 10, 64) or { u64(0) } * 4,
		children: []int{},
	}
}

fn walk_proc() []ProcNode {
	entries := os.ls('/proc') or { return [] }
	mut nodes := map[int]ProcNode{}

	for entry in entries {
		pid := strconv.atoi(entry) or { continue }
		if node := parse_proc(pid) {
			nodes[pid] = node
		}
	}

	// Wire up children
	mut roots := []ProcNode{}
	for pid, node in nodes {
		if node.ppid > 0 {
			if mut parent := nodes[node.ppid] {
				parent.children << pid
				nodes[node.ppid] = parent
			}
		}
	}

	for _, node in nodes {
		roots << node
	}

	roots.sort_with_compare(fn(a &ProcNode, b &ProcNode) int {
		if a.rss_kb > b.rss_kb { return -1 }
		if a.rss_kb < b.rss_kb { return  1 }
		return 0
	})
	return roots
}

struct Output {
	type_  string      [json: 'type']
	ts_ms  i64         [json: 'ts_ms']
	procs  []ProcNode  [json: 'procs']
}

fn main() {
	for {
		procs := walk_proc()
		out   := Output{
			type_: 'proctree',
			ts_ms: time.now().unix_milli(),
			procs: procs,
		}
		println(json.encode(out))
		time.sleep(1 * time.second)
	}
}
