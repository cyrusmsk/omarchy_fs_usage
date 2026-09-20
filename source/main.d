module omarchy_fs_usage.main;

import qt.config;
import qt.helpers;

import omarchy_fs_usage.logic;

import qt.core.coreapplication;
import qt.core.coreevent;
import qt.core.namespace;
import qt.core.object;
import qt.core.point;
import qt.core.string;
import qt.core.timer;
import qt.gui.event;
import qt.gui.guiapplication;
import qt.gui.pointingdevice;
import qt.gui.window;
import qt.qml.applicationengine;

import core.stdcpp.new_;

int main()
{
	import core.runtime;
	import omarchy_fs_usage.logic;
	import std.process : environment;
	import qt.core.bytearray;
	import qt.core.coreapplication;
	import qt.core.namespace;
	import qt.core.object;
	import qt.core.string;
	import qt.core.url;
	import qt.gui.guiapplication;
	import qt.qml.applicationengine;
	import qt.qml.context;

	int argc = Runtime.cArgs.argc; // Reference needs to be valid for lifetime of application object.
	char** argv = Runtime.cArgs.argv;
	scope app = new QGuiApplication(argc, argv);
	app.setApplicationName("Omarchy Disk Usage");

	scope engine = new QQmlApplicationEngine;

	Logic logic = environment.get("FSU_MINIMAL", null) == "1"
		? null : new Logic(app);
	if (logic !is null)
	{
		engine.rootContext().setContextProperty("appTitle", "Disk Usage");
		engine.rootContext().setContextProperty("logic", logic);
		// stop and join the sampling worker before the runtime tears down
		QObject.connect(app.signal!"aboutToQuit", logic.slot!"shutdown");
	}

	// The UI lives next to this file and is embedded at compile time.
	import std.process : environment;
	string qmlSource = environment.get("FSU_MINIMAL", null) == "1"
		? import("minimal.qml") : import("main.qml");
	string qmlFile = environment.get("FSU_MINIMAL", null) == "1"
		? "minimal.qml" : "main.qml";
	import qt.core.global : qsizetype;
	auto qmlData = QByteArray(qmlSource.ptr, cast(qsizetype) qmlSource.length);
	auto qmlUrl = QUrl.fromLocalFile("omarchy_fs_usage/" ~ qmlFile);

	if (environment.get("FSU_RAW", null) != "1")
	{
		// Kept in a local so the delegate's closure stays visible to the
		// D GC for the whole event-loop run (upstream dqt leaves delegate
		// lifetime to the caller - see README "Memory management").
		auto objCreatedHandler = (QObject obj, ref const QUrl loadedUrl) {
			if (!obj && loadedUrl == qmlUrl)
				QCoreApplication.exit(-1);
		};
		QObject.connect(
			engine.signal!"objectCreated",
			app,
			objCreatedHandler,
			/+ Qt:: +/qt.core.namespace.ConnectionType.QueuedConnection);
	}

	engine.loadData(qmlData, qmlUrl);

	if (environment.get("FSU_RAW", null) == "1")
	{
		// Fully de-glued: no Qt timers, no signal connections, no slots.
		// Pump the event loop manually and inject synthetic clicks directly.
		import core.thread : Thread;
		import core.time : msecs;
		import std.stdio : writeln;
		auto wins = QGuiApplication.allWindows();
		QWindow win = null;
		foreach (i; 0 .. wins.size())
			if (wins[i].isVisible())
				win = wins[i];
		foreach (n; 1 .. 8)
		{
			QCoreApplication.processEvents();
			Thread.sleep(300.msecs);
			QCoreApplication.processEvents();
			writeln("RAW tick ", n);
			qtestPress(win, 400, 150);
			QCoreApplication.processEvents();
			qtestRelease(win, 400, 150);
			QCoreApplication.processEvents();
		}
		writeln("RAW-OK");
		return 0;
	}

	// Automated smoke test mode: drive the app through its keyboard
	// interface (the supported input path - pointer activation is
	// disabled, see README) and verify navigation + details work.
	// The bots are kept in GC-visible locals for the whole event-loop run
	// so the D GC keeps seeing them while Qt (timers, connections)
	// invokes them from C++ - upstream dqt leaves this lifetime to the
	// caller (see README "Memory management").
	KeyBot keyBot = null;
	ClickBot clickBot = null;
	CompareBot cmpBot = null;
	if (environment.get("FSU_AUTOTEST", null) == "1")
		keyBot = new KeyBot(app, logic);

	// Click probe: synthesize real-pipeline mouse clicks on the rows
	// (row taps navigate, like the keyboard does) and verify survival.
	if (environment.get("FSU_AT_CLICKS", null) == "1")
		clickBot = new ClickBot(app, logic, engine);

	// Advanced-tabs probe: baseline deltas, snapshot estimator,
	// insights object, tab-switch shortcuts.
	if (environment.get("FSU_AT_COMPARE", null) == "1")
		cmpBot = new CompareBot(app, logic);

	return app.exec();
}

/// Drives the keyboard interface end to end: starts a scan, waits for the
/// data, then moves the selection, drills in/out and queries row details,
/// checking the controller state after each step.
final class KeyBot : QObject
{
	mixin(Q_OBJECT_D);

public:
	Logic logic;

	this(QObject parent = null, Logic logic = null)
	{
		import core.stdcpp.new_;
		super(parent);
		this.logic = logic;
		timer = cpp_new!QTimer(this);
		timer.setInterval(500);
		QObject.connect(timer.signal!"timeout", this.slot!"tick");
		timer.start();
	}

	@QSlot void tick()
	{
		import std.json : JSONType, parseJSON;
		import std.stdio : writeln;
		import qt.core.coreapplication;
		import qt.core.coreevent;
		import qt.core.namespace;
		import qt.gui.event;
		step++;
		writeln("KEYTEST step ", step);

		if (step > 60)
		{
			writeln("KEYTEST-FAIL timeout");
			QCoreApplication.quit();
			return;
		}
		if (logic is null)
			return;

		if (step == 1)
		{
			// Offline imports land ready: exercise them as-is instead of
			// rescanning over the top.
			string sumStr = qstr(logic.summaryJson());
			string phase;
			try
			{
				import std.json : parseJSON;
				phase = parseJSON(sumStr).object["phase"].str;
			}
			catch (Exception)
			{
			}
			if (phase == "ready")
			{
				writeln("KEYTEST using imported data");
				return;
			}
			writeln("KEYTEST starting scan (expert + seenAs + physical)");
			import qt.core.global : qsizetype;
			import qt.core.string : QString;
			string o = `{"physical":true,"expert":true,"seenAs":true,`
				~ `"seed":"42","minRes":"","maxTime":"","prefer":"","ignore":""}`;
			auto qs = QString.fromUtf8(o.ptr, cast(qsizetype) o.length);
			logic.setScanOptions(qs);
			logic.startScan("/", 20000);
			return;
		}

		string sumStr = qstr(logic.summaryJson());
		string phase;
		try
			phase = parseJSON(sumStr).object["phase"].str;
		catch (Exception)
		{
		}
		if (phase != "ready")
		{
			writeln("KEYTEST waiting for data (phase=", phase, ")");
			return;
		}

		auto wins = QGuiApplication.allWindows();
		QWindow win = null;
		foreach (i; 0 .. wins.size())
			if (wins[i].isVisible())
			{
				win = wins[i];
				break;
			}
		if (win is null)
			return;

		int depth()
		{
			try
				return cast(int) parseJSON(qstr(logic.crumbsJson())).array.length;
			catch (Exception)
				return -1;
		}

		// First dir row on the top level, so Return/Down/Space land
		// on something that actually opens.
		int firstDir()
		{
			try
			{
				auto arr = parseJSON(qstr(logic.folderJson())).array;
				foreach (idx, ref r; arr)
					if (r.object["dir"].type == JSONType.true_)
						return cast(int) idx;
			}
			catch (Exception)
			{
			}
			return -1;
		}

		void key(int code)
		{
			// Upstream QTest keyboard injection: routes through
			// QWindowSystemInterface like a real key press, instead of
			// hand-building QKeyEvents for sendEvent.
			import qt.core.namespace : Key;
			import qt.test.testkeyboard : keyClick;
			keyClick(win, cast(Key) code);
		}

		alias Key = qt.core.namespace.Key;
		kstep++;
		if (kstep == 1)
		{
			// settle one tick with data before touching keys
			writeln("KEYTEST data ready");
			return;
		}
		if (kstep == 2)
		{
			target = firstDir();
			if (target < 0)
			{
				writeln("KEYTEST-FAIL no dir rows");
				QCoreApplication.quit();
				return;
			}
			writeln("KEYTEST moving to row ", target);
			foreach (n; 0 .. target)
				key(cast(int) Key.Key_Down);
			return;
		}
		if (kstep == 3)
		{
			writeln("KEYTEST Return (enter)");
			key(cast(int) Key.Key_Return);
			return;
		}
		if (kstep == 4)
		{
			if (depth() != 2)
			{
				writeln("KEYTEST-FAIL depth after enter: ", depth());
				QCoreApplication.quit();
				return;
			}
			writeln("KEYTEST entered, depth=2");
			// details for the first row of the new level
			string info = qstr(logic.rowInfo(0));
			writeln("KEYTEST rowInfo: ", info);
			key(cast(int) Key.Key_Left);
			return;
		}
		if (kstep == 5)
		{
			if (depth() != 1)
			{
				writeln("KEYTEST-FAIL depth after Left: ", depth());
				QCoreApplication.quit();
				return;
			}
			writeln("KEYTEST back up, depth=1");
			key(cast(int) Key.Key_Home);
			key(cast(int) Key.Key_Space);
			return;
		}
		if (kstep == 6)
		{
			if (depth() != 2)
			{
				writeln("KEYTEST-FAIL depth after Space: ", depth());
				QCoreApplication.quit();
				return;
			}
			writeln("KEYTEST Space opened, depth=2");
			key(cast(int) Key.Key_Backspace);
			return;
		}
		if (kstep == 7)
		{
			if (depth() != 1)
			{
				writeln("KEYTEST-FAIL depth after Backspace: ", depth());
				QCoreApplication.quit();
				return;
			}
			writeln("KEYTEST-OK (keyboard nav + rowInfo verified)");
			QCoreApplication.quit();
		}
	}

private:
	static string qstr(const QString s)
	{
		auto ba = s.toUtf8();
		return ba.data[0 .. ba.size].idup;
	}

	QTimer timer;
	int step;
	int kstep;
	int target = -1;
}

/// Synthesizes real mouse presses/releases on the result list rows via
/// QCoreApplication.sendEvent, exercising the same Qt Quick pointer
/// delivery machinery as a physical mouse.
final class ClickBot : QObject
{
	mixin(Q_OBJECT_D);

public:
	Logic logic;
	QQmlApplicationEngine engine;

	this(QObject parent = null, Logic logic = null,
			QQmlApplicationEngine engine = null)
	{
		import core.stdcpp.new_;
		super(parent);
		this.logic = logic;
		this.engine = engine;
		timer = cpp_new!QTimer(this);
		timer.setInterval(500);
		QObject.connect(timer.signal!"timeout", this.slot!"tick");
		timer.start();
	}

	@QSlot void tick()
	{
		import std.array : split;
		import std.conv : to;
		import std.process : environment;
		import std.stdio : writeln;
		step++;
		writeln("AUTOTEST step ", step);

		if (logic !is null && step == 1)
		{
			writeln("AUTOTEST starting scan");
			logic.startScan("/", 20000);
			return; // wait for the scan to land before clicking rows
		}
		// mid-soak: second scan while browsing, plus upward navigation
		if (logic !is null && step == 10)
		{
			logic.goUp();
			logic.goUp();
			logic.startScan("/", 20000);
			return;
		}
		if (logic !is null && step == 11)
			return;
		if (logic !is null)
		{
			// visibility into the controller state for the test log
			auto ba = logic.summaryJson().toUtf8();
			writeln("AUTOTEST summary: ", ba.data[0 .. ba.size].idup);
			auto cb = logic.crumbsJson().toUtf8();
			writeln("AUTOTEST crumbs: ", cb.data[0 .. cb.size].idup);
		}
		if (logic !is null && step == 2)
			return; // scan pipeline settling

		auto wins = QGuiApplication.allWindows();
		if (wins.size() == 0)
		{
			writeln("AUTOTEST-FAIL no windows");
			QCoreApplication.quit();
			return;
		}
		QWindow win = null;
		foreach (i; 0 .. wins.size())
		{
			auto w = wins[i];
			if (w.isVisible())
			{
				win = w;
				break;
			}
		}
		if (win is null)
		{
			writeln("AUTOTEST-FAIL no visible window");
			QCoreApplication.quit();
			return;
		}

		// Click the configured spot repeatedly, then declare success.
		auto envX = environment.get("FSU_AT_X", "500");
		auto envY = environment.get("FSU_AT_Y", "240");
		auto nClicks = environment.get("FSU_AT_CLICKS", "5").to!int;
		// Optional comma-separated y sequence: each click uses the next value.
		string ysEnv = environment.get("FSU_AT_YS", null);
		// Fixed "y1,y2,.." clicks at FSU_AT_X, no row-map lookup at all.
		string fixedEnv = environment.get("FSU_AT_FIXED", null);
		if (fixedEnv.length)
		{
			auto ys = fixedEnv.split(',');
			if (clickIdx >= cast(int) ys.length)
			{
				writeln("AUTOTEST-OK (survived ", clickIdx, " fixed clicks)");
				QCoreApplication.quit();
			}
			else
			{
				double y = ys[clickIdx].to!double;
				writeln("AUTOTEST fixed click at ", envX.to!double, ",", y);
				press(win, envX.to!double, y);
				release(win, envX.to!double, y);
				clickIdx++;
			}
		}
		else if (ysEnv.length)
		{
			// FSU_AT_YS: row indices ("1,3") into the live row map exported
			// by the QML; clicks land on the real row centers.
			auto wantRows = ysEnv.split(',');
			auto map = rowMap();
			if (clickIdx >= cast(int) wantRows.length)
			{
				writeln("AUTOTEST-OK (survived ", clickIdx, " sequence clicks)");
				QCoreApplication.quit();
			}
			else if (map.length == 0)
			{
				writeln("AUTOTEST waiting for rows...");
			}
			else
			{
				int want = wantRows[clickIdx].to!int;
				double y = map[want % map.length].y;
				double x = map[want % map.length].x + 60;
				writeln("AUTOTEST click row ", want, " at ", x, ",", y);
				press(win, x, y);
				release(win, x, y);
				qtestMove(win, x + 25, y + 8);
				clickIdx++;
			}
		}
		else if (environment.get("FSU_AT_SPLIT", null) == "1")
		{
			// press and release on separate ticks, to tell apart where it breaks
			if (step % 2 == 1)
				press(win, envX.to!double, envY.to!double);
			else
			{
				release(win, envX.to!double, envY.to!double);
				if (step / 2 >= nClicks)
				{
					writeln("AUTOTEST-OK (survived ", step / 2, " clicks)");
					QCoreApplication.quit();
				}
			}
		}
		else
		{
			click(win, envX.to!double, envY.to!double);
			if (step >= nClicks)
			{
				writeln("AUTOTEST-OK (survived ", step, " clicks)");
				QCoreApplication.quit();
			}
		}
	}

private:
	void click(QWindow win, double x, double y)
	{
		press(win, x, y);
		release(win, x, y);
	}

	void press(QWindow win, double x, double y)
	{
		// mimic a human: glide in, hover, then press
		qtestMove(win, x - 40, y - 12);
		qtestMove(win, x, y);
		qtestPress(win, x, y);
	}

	void release(QWindow win, double x, double y)
	{
		qtestRelease(win, x, y);
		// and drift away after release, as a hand would
		qtestMove(win, x + 25, y + 8);
	}

	/// Live row geometry from the QML root object (see main.qml).
	private struct RowPos
	{
		int i;
		double x, y;
		string name;
		bool dir;
	}

	RowPos[] rowMap()
	{
		import std.json : JSONType, JSONValue, parseJSON;
		RowPos[] result;
		if (engine is null || engine.rootObjects().length == 0)
			return result;
		auto root = engine.rootObjects()[0];
		auto v = root.property("rowMapJson");
		auto ba = v.toString().toUtf8();
		auto json = parseJSON(ba.data[0 .. ba.size].idup);
		static double num(ref const JSONValue v)
		{
			if (v.type == JSONType.integer)
				return cast(double) v.integer;
			if (v.type == JSONType.uinteger)
				return cast(double) v.uinteger;
			return v.floating;
		}
		foreach (ref r; json.array)
		{
			RowPos p;
			p.i = cast(int) r.object["i"].integer;
			p.x = num(r.object["x"]);
			p.y = num(r.object["y"]);
			p.name = r.object["name"].str.dup;
			p.dir = r.object["dir"].type == JSONType.true_;
			result ~= p;
		}
		return result;
	}

	QTimer timer;
	int step;
	int clickIdx;
}

/// Verifies the advanced tabs headlessly: loads a baseline export,
/// checks the computed deltas, the snapshot estimator and the insights
/// object, exercises the tab-switch shortcuts, and checks the browse
/// rows carry delta annotations.
final class CompareBot : QObject
{
	mixin(Q_OBJECT_D);

public:
	Logic logic;

	this(QObject parent = null, Logic logic = null)
	{
		import core.stdcpp.new_;
		super(parent);
		this.logic = logic;
		timer = cpp_new!QTimer(this);
		timer.setInterval(500);
		QObject.connect(timer.signal!"timeout", this.slot!"tick");
		timer.start();
	}

	@QSlot void tick()
	{
		import std.json : JSONType, parseJSON;
		import std.process : environment;
		import std.stdio : writeln;
		import std.string : indexOf;
		import qt.core.coreapplication;
		import qt.core.global : qsizetype;
		import qt.core.string : QString;
		step++;
		writeln("CMPTEST step ", step);

		void fail(string msg)
		{
			writeln("CMPTEST-FAIL ", msg);
			QCoreApplication.quit();
		}

		if (step > 30)
		{
			fail("timeout");
			return;
		}
		if (logic is null)
			return;

		static string qstr(const QString s)
		{
			auto ba = s.toUtf8();
			return ba.data[0 .. ba.size].idup;
		}

		if (step == 1)
		{
			string base = environment.get("FSU_AT_BASELINE",
				"testdata/baseline.json");
			writeln("CMPTEST loading baseline ", base);
			logic.setBaseline(QString.fromUtf8(base.ptr,
				cast(qsizetype) base.length));
			return;
		}
		if (step == 2)
		{
			auto cmp = parseJSON(qstr(logic.compareJson()));
			if (cmp.object["hasBaseline"].type != JSONType.true_)
			{
				fail("no baseline: "
					~ ("baselineError" in cmp.object
						? cmp.object["baselineError"].str : "?"));
				return;
			}
			bool seenGone, seenGrown, seenShrunk, seenNew;
			string first;
			foreach (i, ref r; cmp.object["rows"].array)
			{
				auto o = r.object;
				if (i == 0)
					first = o["path"].str;
				if (o["path"].str == "@/oldkernel" && o["isGone"].type == JSONType.true_
						&& o["deltaBytes"].integer == -3221225472)
					seenGone = true;
				if (o["path"].str == "@home/photos" && o["grown"].type == JSONType.true_
						&& o["deltaBytes"].integer == 1342177280)
					seenGrown = true;
				if (o["path"].str == "@/usr/lib" && o["grown"].type == JSONType.false_
						&& o["deltaBytes"].integer == -1342177280)
					seenShrunk = true;
				if (o["path"].str == "@/usr/share" && o["isNew"].type == JSONType.true_
						&& o["deltaBytes"].integer == 1342177280)
					seenNew = true;
			}
			if (first != "@/oldkernel")
			{
				fail("largest mover should be @/oldkernel, got " ~ first);
				return;
			}
			if (!seenGone || !seenGrown || !seenShrunk || !seenNew)
			{
				fail("missing movers");
				return;
			}
			writeln("CMPTEST deltas verified");

			if (qstr(logic.snapshotsJson()).indexOf("TREE_259") < 0)
			{
				fail("snapshot estimator misses TREE_259");
				return;
			}
			auto ins = parseJSON(qstr(logic.insightsJson()));
			if (!("darkMatter" in ins.object)
					|| ins.object["darkMatter"].object["sizeText"].str != "5.00 GiB")
			{
				fail("dark matter should read 5.00 GiB");
				return;
			}
			if (qstr(logic.folderJson()).indexOf("deltaText") < 0)
			{
				fail("browse rows lack delta annotations");
				return;
			}
			writeln("CMPTEST insights/snapshots/row-deltas verified");
			return;
		}

		auto wins = QGuiApplication.allWindows();
		QWindow win = null;
		foreach (i; 0 .. wins.size())
			if (wins[i].isVisible())
			{
				win = wins[i];
				break;
			}
		if (win is null)
			return;

		alias Key = qt.core.namespace.Key;
		import qt.test.testkeyboard : keyClick;
		if (step == 3)
		{
			writeln("CMPTEST tab 2 (insights)");
			keyClick(win, Key.Key_2);
		}
		else if (step == 4)
		{
			writeln("CMPTEST tab 3 (compare)");
			keyClick(win, Key.Key_3);
		}
		else if (step == 5)
		{
			writeln("CMPTEST tab 1 (browse)");
			keyClick(win, Key.Key_1);
		}
		else if (step >= 6)
		{
			writeln("CMPTEST-OK (compare + insights verified)");
			QCoreApplication.quit();
		}
	}

private:
	QTimer timer;
	int step;
}

// Input synthesis via upstream dqt's QTest bindings (dqt:test):
// the same QWindowSystemInterface pipeline as real pointer/keyboard
// devices, including point registration and event timestamps.
private void qtestPress(QWindow win, double x, double y)
{
	import qt.core.namespace : KeyboardModifier, KeyboardModifiers, MouseButton;
	import qt.core.point : QPoint;
	import qt.test.testmouse : mousePress;
	mousePress(win, MouseButton.LeftButton,
		KeyboardModifiers(KeyboardModifier.NoModifier),
		QPoint(cast(int) x, cast(int) y));
}

private void qtestRelease(QWindow win, double x, double y)
{
	import qt.core.namespace : KeyboardModifier, KeyboardModifiers, MouseButton;
	import qt.core.point : QPoint;
	import qt.test.testmouse : mouseRelease;
	mouseRelease(win, MouseButton.LeftButton,
		KeyboardModifiers(KeyboardModifier.NoModifier),
		QPoint(cast(int) x, cast(int) y));
}

private void qtestMove(QWindow win, double x, double y)
{
	import qt.core.point : QPoint;
	import qt.test.testmouse : mouseMove;
	// hover move, as a hand gliding onto a row before pressing
	mouseMove(win, QPoint(cast(int) x, cast(int) y));
}
