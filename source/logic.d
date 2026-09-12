module omarchy_fs_usage.logic;

import qt.config;
import qt.core.object;
import qt.core.string;
import qt.core.timer;
import qt.helpers;

import core.runtime : Runtime;
import core.stdc.string : strlen;
import core.stdcpp.new_;

import std.algorithm.searching : canFind;
import std.algorithm.sorting : sort;
import std.array : appender, Appender, join, split;
import std.conv : text;
import std.datetime : MonoTime;
import std.file : dirEntries, exists, mkdir, readText, remove, SpanMode;
import std.format : format;
import std.path : buildPath;
import std.process : environment;
import std.string : indexOf, startsWith, splitLines, strip;
import std.uni : toLower;
import std.utf : UTFException, decode;

import omarchy_fs_usage.btdu;
import omarchy_fs_usage.theme;

// ------------------------------------------------------------- JSON tools

private string toDString(ref const(QString) s)
{
	auto ba = s.toUtf8();
	return ba.data[0 .. ba.size].idup;
}

private QString toQString(string s)
{
	import qt.core.global : qsizetype;
	return QString.fromUtf8(s.ptr, cast(qsizetype) s.length);
}

/// btdu names are raw filesystem bytes; keep the JSON stream valid.
private string sanitize(string s)
{
	if (s is null)
		return "";
	auto app = appender!string;
	size_t i;
	while (i < s.length)
	{
		try
		{
			dchar d = decode(s, i);
			app.put(d);
		}
		catch (UTFException)
		{
			auto c = s[i];
			app.put(cast(dchar) (c >= 0x20 && c < 0x7f ? c : '?'));
			i++;
		}
	}
	return app.data;
}

/// Minimal JSON writer (std.json in this toolchain lacks the builder API).
struct Json
{
	Appender!string buf;
	bool inArray;
	bool has;

	this(bool isArray)
	{
		inArray = isArray;
		buf.put(isArray ? '[' : '{');
	}

	private void sep()
	{
		if (has)
			buf.put(',');
		has = true;
	}

	void key(string k)
	{
		sep();
		writeEscaped(k);
		buf.put(':');
	}

	void writeEscaped(string s)
	{
		buf.put('"');
		foreach (dchar c; sanitize(s))
		{
			switch (c)
			{
				case '"':  buf.put("\\\""); break;
				case '\\': buf.put("\\\\"); break;
				case '\b': buf.put("\\b"); break;
				case '\f': buf.put("\\f"); break;
				case '\n': buf.put("\\n"); break;
				case '\r': buf.put("\\r"); break;
				case '\t': buf.put("\\t"); break;
				default:
					if (c < 0x20)
						buf.put(format("\\u%04x", cast(int) c));
					else
						buf.put(c);
			}
		}
		buf.put('"');
	}

	void str(string k, string v) { key(k); writeEscaped(v); }
	void num(string k, long v) { key(k); buf.put(text(v)); }
	void num(string k, double v) { key(k); buf.put(text(v)); }
	void boolean(string k, bool v) { key(k); buf.put(v ? "true" : "false"); }

	string finish()
	{
		buf.put(inArray ? ']' : '}');
		return buf.data;
	}
}

/// A JSON array of pre-rendered object strings.
private string jsonArray(string[] objects)
{
	auto app = appender!string;
	app.put('[');
	foreach (i, o; objects)
	{
		if (i)
			app.put(',');
		app.put(o);
	}
	app.put(']');
	return app.data;
}

// ------------------------------------------------------------------ logic

/// Controller exposed to QML. Runs `btdu --headless` as a subprocess, parses
/// the exported JSON tree, and serves one "folder" of the result at a time in
/// ncdu style. All QML-facing data crosses the boundary as JSON strings that
/// the UI parses with JSON.parse().
class Logic : QObject
{
	mixin(Q_OBJECT_D);
public:
	/+ explicit +/this(QObject parent = null)
	{
		super(parent);

		m_folderJson = toQString("[]");
		m_crumbsJson = toQString("[]");
		m_themeJson = toQString(omarchyThemeJson());
		m_mountsJson = toQString(discoverMountsJson());

		exportDir = buildPath(tempDirName(), "omarchy_fs_usage." ~ uniqueSuffix());
		try
			mkdir(exportDir);
		catch (Throwable)
		{
		}

		// Offline browsing: accept a previously exported btdu scan
		// (positional .json argument, or the BTDU_IMPORT environment variable).
		string importFile;
		foreach (a; Runtime.cArgs.argv[1 .. Runtime.cArgs.argc])
		{
			string arg = a[0 .. strlen(a)].idup;
			if (arg == "--import" || arg == "-i")
				continue;
			if (arg.length > 5 && arg[$ - 5 .. $] == ".json" && arg.exists)
				importFile = arg;
		}
		if (importFile is null)
			importFile = environment.get("BTDU_IMPORT", null);

		if (importFile.length && importFile.exists && acceptImport(importFile))
		{
			// keep the import sticky: subsequent polls must not clobber it
		}
		else
		{
			Json s = Json(false);
			s.str("phase", "idle");
			s.boolean("ready", false);
			s.str("note", "btdu samples randomly: 20k is a first estimate, "
				~ "200k gives roughly 1% resolution.");
			setSummaryJson(s.finish());
		}

		pollTimer = cpp_new!QTimer(this);
		pollTimer.setInterval(150);
		QObject.connect(pollTimer.signal!"timeout", this.slot!"onPoll");
		pollTimer.start();
	}

	~this()
	{
		if (job !is null)
			job.cancel();
		try
			foreach (de; dirEntries(exportDir, SpanMode.shallow))
				remove(de.name);
		catch (Throwable)
		{
		}
	}

	// ------------------------------------------------------------ properties

	private QString m_themeJson;
	@QPropertyDef("themeJson", isConstant: true)
	final QString themeJson()
	{
		return m_themeJson;
	}

	private QString m_mountsJson;
	@QPropertyDef("mountsJson", isConstant: true)
	final QString mountsJson()
	{
		return m_mountsJson;
	}

	private QString m_folderJson;
	@QPropertyDef
	{
		final QString folderJson() const
		{
			return m_folderJson;
		}
		final void setFolderJson(ref const(QString) v)
		{
			if (m_folderJson != v)
			{
				m_folderJson = v;
				/+ emit +/ folderJsonChanged();
			}
		}
		@QSignal final void folderJsonChanged() {mixin(Q_SIGNAL_IMPL_D);}
	}

	private QString m_summaryJson;
	@QPropertyDef
	{
		final QString summaryJson() const
		{
			return m_summaryJson;
		}
		final void setSummaryJson(ref const(QString) v)
		{
			if (m_summaryJson != v)
			{
				m_summaryJson = v;
				/+ emit +/ summaryJsonChanged();
			}
		}
		@QSignal final void summaryJsonChanged() {mixin(Q_SIGNAL_IMPL_D);}
	}

	private QString m_crumbsJson;
	@QPropertyDef
	{
		final QString crumbsJson() const
		{
			return m_crumbsJson;
		}
		final void setCrumbsJson(ref const(QString) v)
		{
			if (m_crumbsJson != v)
			{
				m_crumbsJson = v;
				/+ emit +/ crumbsJsonChanged();
			}
		}
		@QSignal final void crumbsJsonChanged() {mixin(Q_SIGNAL_IMPL_D);}
	}

	// ---------------------------------------------------------------- actions

	/// Start a headless btdu sampling run on `path` (a btrfs mount point).
	@QSlot final void startScan(ref const(QString) path, int budget)
	{
		if (running)
			return;

		if (!findBtdu().length)
		{
			Json s = Json(false);
			s.str("phase", "error");
			s.boolean("ready", treeRoot !is null);
			s.str("error", "btdu executable not found. Install it "
				~ "(e.g. `sudo pacman -S btdu`) or set BTDU_PATH to its location.");
			setSummaryJson(s.finish());
			return;
		}

		scanPath = toDString(path);
		lastBudget = budget;
		running = true;
		runningSince = MonoTime.currTime;

		job = new ScanJob(scanPath,
			buildPath(exportDir, "scan-" ~ uniqueSuffix() ~ ".json"), budget, opts);
		job.start();

		Json s = Json(false);
		s.str("phase", "sampling");
		s.boolean("ready", treeRoot !is null);
		s.str("scanPath", scanPath);
		s.num("budget", budget);
		s.str("note", "btdu reads raw filesystem metadata as root — "
			~ "polkit will ask for your password.");
		setSummaryJson(s.finish());
	}

	@QSlot final void stopScan()
	{
		if (running && job !is null)
			job.cancel();
	}

	/// Called from QGuiApplication.aboutToQuit: stop and join the sampling
	/// worker so nothing runs (or gets freed) during runtime teardown.
	@QSlot final void shutdown()
	{
		if (job !is null)
		{
			job.cancel();
			job.joinWorker();
		}
	}

	/// Open the folder shown on the given row of the current view.
	@QSlot final void enter(int row)
	{
		if (row < 0 || row >= cast(int) viewRows.length)
			return;
		auto node = viewRows[row];
		if (node is null || node.children.length == 0)
			return;
		stack ~= node;
		rebuildView();
	}

	/// Details for the given row: exclusive (own) vs shared split plus the
	/// `seenAs` attribution (which other paths share these extents: CoW
	/// clones and snapshots). Returned as a JSON object string.
	@QSlot final QString rowInfo(int row)
	{
		Json j = Json(false);
		if (row < 0 || row >= cast(int) viewRows.length || viewRows[row] is null)
		{
			j.boolean("ok", false);
			return toQString(j.finish());
		}
		auto k = viewRows[row];
		auto info = nodeInfo(*k);
		bool expert = lastExpert && k.samples > 0;
		j.boolean("ok", true);
		j.str("name", info.display);
		j.str("kind", info.kind);
		j.str("desc", info.desc);
		j.str("sizeText", humanSize(sizeBytes(k.samples)));
		if (expert)
		{
			ulong own = k.exclusive <= k.samples ? k.exclusive : k.samples;
			ulong sh = k.shared_ <= k.samples ? k.shared_ : 0;
			j.str("ownText", humanSize(sizeBytes(own)) ~ " own");
			j.str("sharedText", humanSize(sizeBytes(sh)) ~ " shared");
			j.num("ownPct", round1(own * 100.0 / k.samples));
			j.num("sharedPct", round1(sh * 100.0 / k.samples));
		}
		if (k.seenAs.length)
		{
			string[] paths;
			ulong cap = k.seenAs.length < 8 ? k.seenAs.length : 8;
			foreach (s; k.seenAs[0 .. cap])
			{
				Json p = Json(false);
				p.str("path", s.path);
				p.str("sizeText", humanSize(sizeBytes(s.samples)));
				p.num("pct", k.samples
					? round1(s.samples * 100.0 / k.samples) : 0);
				paths ~= p.finish();
			}
			j.key("seenAs");
			// Json has no array helper for raw values; splice one in.
			j.buf.put(jsonArray(paths));
		}
		return toQString(j.finish());
	}

	@QSlot final void goUp()
	{
		if (stack.length > 1)
		{
			stack = stack[0 .. $ - 1];
			rebuildView();
		}
	}

	@QSlot final void goToLevel(int level)
	{
		if (level >= 0 && level + 1 <= stack.length && level != cast(int) stack.length - 1)
		{
			stack = stack[0 .. level + 1];
			rebuildView();
		}
	}

	@QSlot final void setFilter(ref const(QString) f)
	{
		filter = toDString(f);
		if (treeRoot !is null)
			rebuildView();
	}

	@QSlot final void setSortByName(bool v)
	{
		if (sortByName == v)
			return;
		sortByName = v;
		if (treeRoot !is null)
			rebuildView();
	}

	/// Replace the advanced btdu options (JSON, see ScanOptions.parse);
	/// they take effect on the next scan.
	@QSlot final void setScanOptions(ref const(QString) j)
	{
		opts = ScanOptions.parse(toDString(j));
	}

private:
	/// Load a previously exported btdu scan (JSON) for browsing without root.
	bool acceptImport(string path)
	{
		try
		{
			auto r = ScanJob.parseExportFile(path);
			if (r.error.length)
				throw new Exception(r.error);
			auto flat = flattenProfiles(r.root);
			treeRoot = new ScanNode;
			*treeRoot = flat;
			totalSize = r.totalSize;
			rootSamples = r.root.samples > 0 ? r.root.samples : 1;
			lastExpert = r.expert;
			lastPhysical = r.physical;
			lastFsid = r.fsid;
			scanPathShown = r.fsPath.length ? r.fsPath : path;
			stack = [treeRoot];
			rebuildView();

			Json s = Json(false);
			s.str("phase", "ready");
			s.boolean("ready", true);
			s.str("scanPath", scanPathShown);
			s.str("fsPath", r.fsPath);
			s.num("samples", cast(long) rootSamples);
			s.num("used", cast(long) totalSize);
			s.str("usedText", humanSize(totalSize));
			s.str("resolution", rootSamples > 1 ? humanSize(totalSize / rootSamples) : "?");
			s.boolean("expert", r.expert);
			s.boolean("physical", r.physical);
			s.str("fsid", r.fsid);
			s.str("note", "imported from " ~ path ~ " (offline view - start a scan to refresh)");
			setSummaryJson(s.finish());
			return true;
		}
		catch (Throwable e)
		{
			Json s = Json(false);
			s.str("phase", "error");
			s.boolean("ready", false);
			s.str("error", "Could not import " ~ path ~ ": " ~ e.msg);
			setSummaryJson(s.finish());
			return false;
		}
	}

	// -------------------------------------------------------------- polling

	@QSlot void onPoll()
	{
		if (!running || job is null)
			return;

		if (!job.isFinished)
		{
			long secs = (MonoTime.currTime - runningSince).total!"msecs" / 1000;
			Json s = Json(false);
			s.str("phase", "sampling");
			s.boolean("ready", treeRoot !is null);
			s.str("scanPath", scanPath);
			s.num("budget", lastBudget);
			s.str("elapsed", format("%d:%02d", secs / 60, secs % 60));
			s.str("note", "Collecting random samples…");
			setSummaryJson(s.finish());
			return;
		}

		ScanResult r;
		if (!job.takeResult(r))
			return;

		running = false;
		job = null;

		if (r.error.length)
		{
			Json s = Json(false);
			s.str("phase", "error");
			s.boolean("ready", treeRoot !is null);
			s.str("scanPath", scanPath);
			s.str("error", r.error);
			s.str("log", r.log);
			setSummaryJson(s.finish());
			return;
		}

		auto flat = flattenProfiles(r.root);
		treeRoot = new ScanNode;
		*treeRoot = flat;
		totalSize = r.totalSize;
		rootSamples = r.root.samples > 0 ? r.root.samples : 1;
		lastExpert = r.expert;
		lastPhysical = r.physical;
		lastFsid = r.fsid;
		scanPathShown = scanPath;
		stack = [treeRoot];
		rebuildView();

		long secs = (MonoTime.currTime - runningSince).total!"msecs" / 1000;
		Json s = Json(false);
		s.str("phase", "ready");
		s.boolean("ready", true);
		s.str("scanPath", scanPathShown);
		s.str("fsPath", r.fsPath);
		s.num("samples", cast(long) rootSamples);
		s.num("used", cast(long) totalSize);
		s.str("usedText", humanSize(totalSize));
		s.str("resolution", rootSamples > 1 ? humanSize(totalSize / rootSamples) : "?");
		s.boolean("expert", r.expert);
		s.boolean("physical", r.physical);
		s.str("fsid", r.fsid);
		s.str("elapsed", format("%d:%02d", secs / 60, secs % 60));
		s.str("note", r.log.splitLines.length > 0 ? r.log.splitLines[$ - 1] : null);
		setSummaryJson(s.finish());
	}

	// ------------------------------------------------------------ view build

	void rebuildView()
	{
		if (stack.length == 0)
			return;
		auto cur = stack[$ - 1];

		// The parsed tree is immutable, so children arrays give stable pointers.
		ScanNode*[] kids;
		kids.reserve(cur.children.length);
		foreach (i; 0 .. cur.children.length)
			kids ~= &cur.children[i];

		if (sortByName)
			kids.sort!byName;
		else
			kids.sort!bySize;

		ulong kidsSamples;
		foreach (k; kids)
			kidsSamples += k.samples;
		ulong denom = kidsSamples > 0 ? kidsSamples : 1;

		enum rowLimit = 500;
		string[] rows;
		foreach (i, k; kids)
		{
			auto info = nodeInfo(*k);
			if (k.viaProfiles.length > 1)
				info.desc = (info.desc.length ? info.desc ~ " " : null)
					~ "Aggregated across " ~ k.viaProfiles.join(" + ") ~ " profiles.";
			if (filter.length && !matchesFilter(info.display))
				continue;
			if (rows.length >= rowLimit)
				break;

			Json row = Json(false);
			row.num("i", cast(long) i);
			row.str("name", info.display);
			row.str("kind", info.kind);
			row.str("desc", info.desc);
			row.boolean("dir", k.children.length > 0);
			row.num("bytes", cast(long) sizeBytes(k.samples));
			row.str("sizeText", humanSize(sizeBytes(k.samples)));
			row.str("exclText", k.exclusive < k.samples
				? "~" ~ humanSize(sizeBytes(k.exclusive)) ~ " own" : "");
			if (lastExpert && k.samples > 0)
			{
				ulong own = k.exclusive <= k.samples ? k.exclusive : k.samples;
				ulong sh = k.shared_ <= k.samples ? k.shared_ : 0;
				row.num("ownPct", round1(own * 100.0 / k.samples));
				row.str("sharedText", sh > 0
					? "~" ~ humanSize(sizeBytes(sh)) ~ " shared" : "");
			}
			row.num("pct", round1(k.samples * 100.0 / denom));
			rows ~= row.finish();
		}

		viewRows = kids;
		setFolderJson(jsonArray(rows));

		string[] crumbs;
		foreach (level, nodep; stack)
		{
			Json c = Json(false);
			c.str("label", level == 0
				? (scanPathShown.length ? scanPathShown : "btdu")
				: nodeInfo(*nodep).display);
			c.num("level", cast(long) level);
			crumbs ~= c.finish();
		}
		setCrumbsJson(jsonArray(crumbs));
	}

	static bool bySize(ScanNode* a, ScanNode* b)
	{
		if (a.samples != b.samples)
			return a.samples > b.samples;
		return a.name < b.name;
	}

	static bool byName(ScanNode* a, ScanNode* b)
	{
		bool ad = a.children.length > 0, bd = b.children.length > 0;
		if (ad != bd)
			return ad;
		string x = (a.name is null ? "" : a.name).toLower;
		string y = (b.name is null ? "" : b.name).toLower;
		return x < y;
	}

	bool matchesFilter(string name)
	{
		return name.toLower.indexOf(filter.toLower) >= 0;
	}

	ulong sizeBytes(ulong samples)
	{
		return rootSamples > 1 ? samples * totalSize / rootSamples : 0;
	}

	static double round1(double v)
	{
		return (cast(long) (v * 10 + 0.5)) / 10.0;
	}

	// ------------------------------------------------------------ mount probe

	static string discoverMountsJson()
	{
		struct Mnt
		{
			string device, mount, subvol;
		}

		Mnt[] all;
		try
			foreach (line; readText("/proc/mounts").splitLines)
			{
				auto f = line.split(' ');
				if (f.length >= 3 && f[2] == "btrfs")
				{
					Mnt m;
					m.device = unescapeOctal(f[0]);
					m.mount = unescapeOctal(f[1]);
					if (f.length >= 4)
						foreach (opt; f[3].split(','))
							if (opt.startsWith("subvol="))
								m.subvol = opt[7 .. $];
					all ~= m;
				}
			}
		catch (Throwable)
		{
		}

		// One suggestion per btrfs device: btdu always analyzes whole volumes,
		// so any of its mount points is a valid scan target.
		string[] entries;
		string[] seen;
		foreach (ref m; all)
		{
			if (seen.canFind(m.device))
				continue;
			seen ~= m.device;

			string anchor = m.mount;
			foreach (ref o; all)
				if (o.device == m.device && o.mount == "/")
					anchor = "/";

			string[] subs;
			foreach (ref o; all)
				if (o.device == m.device)
					subs ~= (o.subvol.length ? o.subvol : "/");

			Json e = Json(false);
			e.str("path", anchor);
			e.str("label", anchor ~ " · " ~ m.device ~ " · " ~ subs.join(" "));
			entries ~= e.finish();
		}
		return jsonArray(entries);
	}

	static string unescapeOctal(string s)
	{
		// /proc/mounts escapes special bytes as \040 & friends
		if (s.indexOf('\\') < 0)
			return s;
		auto app = appender!string;
		for (size_t i; i < s.length; i++)
		{
			if (s[i] == '\\' && i + 3 < s.length
					&& s[i + 1] >= '0' && s[i + 1] <= '2'
					&& s[i + 2] >= '0' && s[i + 2] <= '9'
					&& s[i + 3] >= '0' && s[i + 3] <= '9')
			{
				app.put(cast(char) (((s[i + 1] - '0') * 8 + (s[i + 2] - '0')) * 8
					+ (s[i + 3] - '0')));
				i += 3;
			}
			else
				app.put(s[i]);
		}
		return app.data;
	}

	static string tempDirName()
	{
		auto p = environment.get("XDG_RUNTIME_DIR", null);
		if (p.length && p.exists)
			return p;
		return environment.get("TMPDIR", "/tmp");
	}

	static string uniqueSuffix()
	{
		import std.uuid : randomUUID;
		return randomUUID().toString[0 .. 8];
	}

	// ------------------------------------------------------------ state

	QTimer pollTimer;
	ScanJob job;
	bool running;
	MonoTime runningSince;
	string scanPath, scanPathShown, exportDir, filter;
	int lastBudget = 200_000;
	ScanOptions opts;
	bool lastExpert, lastPhysical;
	string lastFsid;

	ScanNode* treeRoot;
	ScanNode*[] stack; /// navigation chain; stack[0] == treeRoot
	ScanNode*[] viewRows;
	ulong totalSize, rootSamples;
	bool sortByName;

	mixin(CREATE_CONVENIENCE_WRAPPERS);
}
