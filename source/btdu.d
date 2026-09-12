module omarchy_fs_usage.btdu;

import core.sync.mutex : Mutex;
import core.sys.posix.unistd : geteuid;
import core.thread : Thread;

import std.algorithm.sorting : sort;
import std.array : appender, split;
import std.conv : to;
import std.process : environment;
import std.file : exists, readText, dirEntries, isDir, SpanMode;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;
import std.process : Pid, Redirect, kill, pipeProcess, wait;
import std.string : splitLines, startsWith, strip;

/// One node of the btdu result tree (a path, profile, or block-type bucket).
struct ScanNode
{
	string name;       /// raw element name, "\0"-prefixed for special buckets
	ulong samples;     /// represented samples
	ulong exclusive;   /// exclusive samples (expert mode only)
	ulong shared_;     /// samples shared with other paths: CoW clones, snapshots (expert mode only)
	SeenAs[] seenAs;   /// where else those shared samples appear (with --export-seen-as)
	ScanNode[] children;
	string[] viaProfiles; /// profiles this node was aggregated from (flattened view)
}

/// One entry of a node's `seenAs` map: a path that shares extents with it.
struct SeenAs
{
	string path;
	ulong samples;
}

/// Outcome of one headless btdu run.
struct ScanResult
{
	ScanNode root;
	ulong totalSize;    /// bytes of used space on the filesystem
	string fsPath;      /// where btdu sampled the top-level subvolume
	string fsid;        /// btrfs filesystem UUID ("xxxxxxxx-..."), if exported
	bool expert;        /// export carries exclusive/shared metrics (-x)
	bool physical;      /// sizes are physical, not logical (-p)
	string log;         /// last lines of btdu output
	string error;       /// non-null when the run failed
}

/// Executable-bit probe (std.file.status is unavailable in this toolchain).
private bool isExecFile(string p)
{
	import core.sys.posix.sys.stat : S_IXUSR, stat, stat_t;
	stat_t st;
	char[] z = (p ~ '\0').dup;
	if (stat(z.ptr, &st) != 0)
		return false;
	return (st.st_mode & S_IXUSR) != 0;
}

/// Minimal PATH lookup.
private string which(string name)
{
	import std.file : exists;
	import std.path : buildPath;
	foreach (dir; environment.get("PATH", "").split(':'))
	{
		auto p = buildPath(dir, name);
		try
			if (isExecFile(p))
				return p;
		catch (Throwable)
		{
		}
	}
	return null;
}

/// Locates the btdu executable.
/// Checked in order: $FSU_FAKE_BTDU (test double), $BTDU_PATH, $PATH,
/// dub package cache builds.
string findBtdu()
{
	// Test hook: a stand-in btdu that replays a canned export, so the
	// whole scan pipeline (worker, polling, parse, render) can be
	// exercised without root privileges.
	string fake = environment.get("FSU_FAKE_BTDU", null);
	if (fake.length && fake.exists)
		return fake;

	string fromEnv = environment.get("BTDU_PATH", null);
	if (fromEnv.length && fromEnv.exists && isExecFile(fromEnv))
		return fromEnv;

	string onPath = which("btdu");
	if (onPath.length)
		return onPath;

	// Fall back to a btdu built from the dub package (e.g. built with
	// `cd ~/.dub/packages/btdu/<ver>/btdu && dub build -b release`).
	string best;
	try
	{
		auto cache = buildPath(environment.get("HOME", ""), ".dub", "packages", "btdu");
		if (!cache.isDir)
			return null;
		string[] candidates;
		foreach (de; cache.dirEntries(SpanMode.shallow))
			if (de.isDir)
			{
				auto bin = buildPath(de.name, "btdu", "btdu");
				if (isExecFile(bin))
					candidates ~= bin;
			}
		candidates.sort; // dub cache dirs sort by version
		if (candidates.length)
			best = candidates[$ - 1];
	}
	catch (Throwable)
	{
	}
	return best;
}

/// Human-readable binary size, in the spirit of btdu's own output.
string humanSize(ulong bytes)
{
	static units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"];
	double v = bytes;
	size_t u;
	while (v >= 1024 && u < units.length - 1)
	{
		v /= 1024;
		u++;
	}
	import std.format : format;
	return u == 0 ? format("%d B", bytes) : format("%.2f %s", v, units[u]);
}

/// Advanced btdu scan options (the btrfs-specific knobs beyond the
/// sample budget). Serialized as JSON between QML and the controller.
struct ScanOptions
{
	bool physical;      /// -p: measure physical instead of logical space
	bool expert;        /// -x: collect exclusive/shared metrics (CoW/snapshot sharing)
	bool seenAs;        /// --export-seen-as: record which paths share each extent
	string seed;        /// --seed: fixed random seed, for reproducible scans
	string minResolution; /// --min-resolution: stop at this resolution ("1%", "10MiB")
	string maxTime;     /// --max-time: stop after this long ("30s", "5m")
	string[] prefer;    /// --prefer: focus sampling on these path patterns
	string[] ignore;    /// --ignore: deprioritize these path patterns

	/// Lenient JSON parse: missing keys keep their defaults.
	static ScanOptions parse(string json)
	{
		import std.json : JSONType, parseJSON;
		ScanOptions o;
		if (!json.length)
			return o;
		try
		{
			auto v = parseJSON(json);
			if (v.type != JSONType.object)
				return o;
			bool flag(string k)
			{
				if (auto p = k in v.object)
					return p.type == JSONType.true_;
				return false;
			}
			string text(string k)
			{
				if (auto p = k in v.object)
					if (p.type == JSONType.string)
						return p.str.dup;
				return null;
			}
			o.physical = flag("physical");
			o.expert = flag("expert");
			o.seenAs = flag("seenAs");
			o.seed = text("seed");
			o.minResolution = text("minRes");
			o.maxTime = text("maxTime");
			o.prefer = splitPatterns(text("prefer"));
			o.ignore = splitPatterns(text("ignore"));
		}
		catch (Exception)
		{
		}
		return o;
	}

	private static string[] splitPatterns(string s)
	{
		import std.array : split;
		import std.string : strip;
		string[] r;
		if (s is null)
			return r;
		foreach (p; s.split(','))
		{
			auto t = p.strip.idup;
			if (t.length)
				r ~= t;
		}
		return r;
	}
}

/// Runs `btdu --headless --export=... <path>` in a worker thread and parses
/// the exported JSON into a ScanNode tree. All mutable hand-off state is
/// guarded by `lock` so the GUI thread may poll the job safely.
final class ScanJob
{
	string btduPath;
	string scanPath;
	string exportFile;
	int sampleBudget = 200_000;
	ScanOptions opts;

private:
	Mutex lock;
	bool done;
	ScanResult result;
	Pid childPid;
	bool cancelRequested;
	Thread worker;

public:
	this(string scanPath, string exportFile, int sampleBudget,
		ScanOptions opts = ScanOptions.init)
	{
		this.lock = new Mutex;
		this.btduPath = findBtdu();
		this.scanPath = scanPath;
		this.exportFile = exportFile;
		this.sampleBudget = sampleBudget;
		this.opts = opts;
	}

	void start()
	{
		auto t = new Thread(&run);
		t.isDaemon = true;
		synchronized (lock)
			worker = t;
		t.start();
	}

	/// Block until the worker thread has finished (used at shutdown, so the
	/// runtime does not tear the GC down under a running parser).
	void joinWorker()
	{
		Thread t;
		synchronized (lock)
			t = worker;
		if (t !is null && t !is Thread.getThis())
			t.join();
	}

	bool isFinished()
	{
		synchronized (lock)
			return done;
	}

	/// Moves the finished result out to the caller (GUI thread).
	bool takeResult(out ScanResult r)
	{
		synchronized (lock)
		{
			if (!done)
				return false;
			r = result;
			return true;
		}
	}

	void cancel()
	{
		synchronized (lock)
		{
			cancelRequested = true;
			if (childPid && childPid.processID > 0)
			{
				try
					childPid.kill(); // pkexec forwards SIGTERM to btdu
				catch (Throwable)
				{
				}
			}
		}
	}

private:
	void run()
	{
		ScanResult r;
		try
		{
			if (!btduPath.length)
				throw new Exception(
					"btdu executable not found. Install it (e.g. `sudo pacman -S btdu`, "
					~ "or build the dub package) or set the BTDU_PATH environment variable.");

			// btdu needs raw device access; elevate via polkit unless we are
			// root (or the test double, which needs no elevation).
			bool fake = environment.get("FSU_FAKE_BTDU", null).length > 0;
			// --prefer/--ignore are rejected together with --auto-mount,
			// so the mount assistance is dropped when patterns are given.
			bool focused = opts.prefer.length > 0 || opts.ignore.length > 0;
			string[] args = (fake || geteuid == 0 ? null : ["pkexec"])
				~ [btduPath, "--headless"]
				~ (focused ? null : ["--auto-mount"]);
			if (opts.physical)
				args ~= "-p";
			if (opts.expert)
				args ~= "-x";
			if (opts.seenAs)
				args ~= "--export-seen-as";
			if (opts.seed.length)
				args ~= ["--seed", opts.seed];
			if (opts.minResolution.length)
				args ~= ["--min-resolution", opts.minResolution];
			if (opts.maxTime.length)
				args ~= ["--max-time", opts.maxTime];
			foreach (p; opts.prefer)
				args ~= ["--prefer", p];
			foreach (p; opts.ignore)
				args ~= ["--ignore", p];
			args ~= ["-n", sampleBudget.to!string,
				"-o", exportFile,
				scanPath];

			auto proc = pipeProcess(args, Redirect.stdout | Redirect.stderrToStdout);
			synchronized (lock)
				childPid = proc.pid;

			string log;
			auto tail = appender!string();
			foreach (line; proc.stdout.byLine)
			{
				log ~= line.idup ~ "\n";
				if (log.length > 64 * 1024)
					log = log[$ - 32 * 1024 .. $];
			}
			foreach (line; log.splitLines)
				if (line.strip.length)
					tail.put(line.strip.idup);
			r.log = tail.data;

			int status = proc.pid.wait();

			if (exportFile.exists)
			{
				try
					r = parseExportFile(exportFile);
				catch (Exception e)
					r.error = "Failed to read btdu results: " ~ e.msg;
			}
			else if (r.error is null)
			{
				if (status == 126 || status == 127)
					r.error = "Authorization declined (polkit refused the privileged btdu run).";
				else
					r.error = "btdu exited with status " ~ status.to!string
						~ (r.log.length ? ":\n" ~ r.log : ".");
			}
		}
		catch (Exception e)
		{
			r.error = e.msg;
		}
		synchronized (lock)
		{
			result = r;
			done = true;
		}
	}

public:
	/// Parse a btdu JSON export (used for live results and offline imports).
	static ScanResult parseExportFile(string path)
	{
		ScanResult r;
		auto doc = parseJSON(readText(path));
		auto o = doc.object;
		r.fsPath = "fsPath" in o ? o["fsPath"].str : null;
		r.totalSize = "totalSize" in o ? jsonUlong(o["totalSize"]) : 0;
		r.fsid = ("fsid" in o && o["fsid"].type == JSONType.string)
			? o["fsid"].str.dup : null;
		r.expert = "expert" in o && o["expert"].type == JSONType.true_;
		r.physical = "physical" in o && o["physical"].type == JSONType.true_;
		r.root = parseNode(o["root"]);
		return r;
	}

private:
	static ulong jsonUlong(JSONValue v)
	{
		if (v.type == JSONType.uinteger)
			return v.uinteger;
		if (v.type == JSONType.integer)
			return cast(ulong) v.integer;
		return 0;
	}

	static ScanNode parseNode(JSONValue v)
	{
		ScanNode n;
		if (v.type != JSONType.object)
			return n;
		auto o = v.object;
		if (auto nm = "name" in o)
			if (nm.type == JSONType.string)
				n.name = nm.str.dup;
		if (auto d = "data" in o)
			if (d.type == JSONType.object)
			{
				ulong sampleOf(string key)
				{
					if (auto s = key in d.object)
						if (s.type == JSONType.object)
							if (auto c = "samples" in s.object)
								return jsonUlong(*c);
					return 0;
				}
			n.samples = sampleOf("represented");
			n.exclusive = sampleOf("exclusive");
			n.shared_ = sampleOf("shared");
		}
		if (auto sa = "seenAs" in o)
			if (sa.type == JSONType.object)
				foreach (k, v; sa.object)
					n.seenAs ~= SeenAs(k.dup, jsonUlong(v));
		n.seenAs.sort!((a, b) => a.samples > b.samples);
		if (auto ch = "children" in o)
			if (ch.type == JSONType.array)
				foreach (ref c; ch.array)
					n.children ~= parseNode(c);
		return n;
	}
}

// ---------------------------------------------------------------------------
// Profile flattening
// ---------------------------------------------------------------------------

private struct Builder
{
	string name;
	ulong samples, exclusive, shared_;
	SeenAs[] seenAs;
	string[] via;
	Builder[] children;
}

private bool containsStr(string[] arr, string s)
{
	foreach (a; arr)
		if (a == s)
			return true;
	return false;
}

/// Find (or create) the slot of `parent`'s child called `name`.
private size_t kidSlot(ref Builder parent, string name)
{
	foreach (i, ref c; parent.children)
		if (c.name == name)
			return i;
	parent.children ~= Builder(name);
	return parent.children.length - 1;
}

/// Fold `src` (a subtree from one profile) into `dst`, merging children by
/// name level by level and summing sample counts.
private void addInto(ref Builder dst, ref const ScanNode src, string profile)
{
	dst.samples += src.samples;
	dst.exclusive += src.exclusive;
	dst.shared_ += src.shared_;
	foreach (ref const s; src.seenAs)
	{
		bool found;
		foreach (ref d; dst.seenAs)
			if (d.path == s.path)
			{
				d.samples += s.samples;
				found = true;
				break;
			}
		if (!found)
			dst.seenAs ~= SeenAs(s.path.idup, s.samples);
	}
	if (profile.length && !containsStr(dst.via, profile))
		dst.via ~= profile;
	foreach (ref const c; src.children)
		addInto(dst.children[kidSlot(dst, c.name)], c, profile);
}

private ScanNode buildFrom(Builder b)
{
	// take by value: the tree is freshly built and ownership moves here
	ScanNode v;
	v.name = b.name;
	v.samples = b.samples;
	v.exclusive = b.exclusive;
	v.shared_ = b.shared_;
	v.seenAs = b.seenAs;
	sortSeenAsDesc(v.seenAs);
	v.viaProfiles = b.via;
	foreach (c; b.children)
		v.children ~= buildFrom(c);
	return v;
}

private void sortSeenAsDesc(ref SeenAs[] a)
{
	import std.algorithm.sorting : sort;
	a.sort!((x, y) => x.samples > y.samples);
}

/// Flatten the profile (SINGLE/DUP/RAID...) and block-type (DATA/METADATA/...)
/// levels into one merged top level, the way the official btdu browser
/// presents it: the interesting buckets become direct children of the root,
/// with the profile information preserved in `viaProfiles`.
ScanNode flattenProfiles(ref const ScanNode root)
{
	Builder merged;
	merged.name = root.name;
	merged.samples = root.samples;
	merged.exclusive = root.exclusive;
	merged.shared_ = root.shared_;
	merged.seenAs = root.seenAs.dup;
	foreach (ref const profile; root.children)
	{
		string pn = profile.name;
		if (pn.length > 1 && pn[0] == 0)
			pn = pn[1 .. $];
		foreach (ref const bucket; profile.children)
			addInto(merged.children[kidSlot(merged, bucket.name)], bucket, pn);
	}

	// Hoist the DATA bucket's children to the top level: they are the
	// actual content (subvolumes, <UNUSED> "dark matter", orphaned
	// subvolumes...), and showing them directly matches the tree of
	// largest items that `btdu --headless` prints. The opaque buckets
	// (<METADATA>, <SYSTEM>, ...) stay as top-level entries.
	Builder hoisted;
	hoisted.name = merged.name;
	hoisted.samples = merged.samples;
	hoisted.exclusive = merged.exclusive;
	hoisted.shared_ = merged.shared_;
	hoisted.seenAs = merged.seenAs;
	foreach (ref bucket; merged.children)
	{
		bool isData = bucket.name.length > 1 && bucket.name[0] == 0
			&& bucket.name[1 .. $] == "DATA";
		if (isData)
			foreach (ref c; bucket.children)
				hoisted.children ~= c;
		else
			hoisted.children ~= bucket;
	}
	return buildFrom(hoisted);
}

// ---------------------------------------------------------------------------
// Node presentation
// ---------------------------------------------------------------------------

/// Display classification of a tree node.
struct NodeInfo
{
	string display;
	string kind; /// root | profile | type | unused | deleted | subvol | dir | file
	string desc;
}

NodeInfo nodeInfo(ref const ScanNode n)
{
	string raw = n.name;
	bool hasKids = n.children.length > 0;

	if (raw is null || !raw.length)
		return NodeInfo("(whole filesystem)", "root", "Sampled btrfs volume");

	if (raw.length > 1 && raw[0] == 0)
	{
		auto tag = raw[1 .. $];
		switch (tag)
		{
			case "DATA":
				return NodeInfo("File data", "type", "Everything a classic analyzer such as du(1) would attribute to files.");
			case "METADATA":
				return NodeInfo("Filesystem metadata", "type", "B-trees, extents and checksums. Opaque to btdu — grows with file count and snapshots, and holds small files inline.");
			case "SYSTEM":
				return NodeInfo("Core filesystem data", "type", "Chunk tree and device mapping structures. Opaque to btdu.");
			case "UNUSED":
				return NodeInfo("Unreachable data", "unused", "The btrfs “dark matter”: space no longer covered by live file extents (overwritten content). Defragmenting or balancing can reclaim it.");
			case "SINGLE":
				return NodeInfo("<SINGLE>", "profile", "Block groups stored as a single copy (the default for data).");
			case "DUP":
				return NodeInfo("<DUP>", "profile", "Block groups written twice (btrfs default for metadata) - costs double the space.");
			case "RAID0", "RAID1", "RAID5", "RAID6", "RAID10", "RAID50", "RAID60":
				return NodeInfo("<" ~ tag ~ ">", "profile", "Block groups using the " ~ tag ~ " replication profile.");
			default:
				if (tag.startsWith("TREE_"))
					return NodeInfo(tag, "deleted", "A deleted subvolume that still holds extents.");
				return NodeInfo("<" ~ tag ~ ">", "special", "Special btdu bucket.");
		}
	}

	if (raw == "@")
		return NodeInfo("System (subvolume @)", "subvol",
			"The @ subvolume — the operating system, mounted at /.");
	if (raw.startsWith("TREE_"))
		return NodeInfo("Deleted subvolume " ~ raw, "deleted",
			"A removed subvolume that still holds extents.");
	if (raw.startsWith("@"))
	{
		if (raw == "@home")
			return NodeInfo("Home (subvolume @home)", "subvol",
				"The @home subvolume — user files, mounted at /home.");
		return NodeInfo("Subvolume " ~ raw, "subvol",
			"A btrfs subvolume" ~ (hasKids ? " — click to browse its contents" : "") ~ ".");
	}

	return NodeInfo(raw, hasKids ? "dir" : "file", null);
}
