module omarchy_fs_usage.theme;

import std.array : appender;
import std.string : splitLines, strip;
import std.process : environment;
import std.string : strip;
import std.file : readText;
import std.json : JSONValue;
import std.regex : ctRegex, matchFirst;

/// Resolve the currently applied Omarchy theme slug (e.g. "tokyo-night"),
/// defaulting to Omarchy's stock theme.
string currentThemeSlug()
{
	string slug;
	try
		slug = readText(environment.get("HOME", "")
			~ "/.local/state/omarchy/current/theme.name").strip;
	catch (Throwable)
	{
	}
	return slug.length ? slug : "catppuccin";
}

/// Load the Omarchy theme palette for the current theme and return it as a
/// JSON object string. User overlays in ~/.config/omarchy/themes win over the
/// stock themes in /usr/share/omarchy/themes, key by key - exactly like the
/// overlay behaviour of `omarchy theme set`.
string omarchyThemeJson()
{
	string slug = currentThemeSlug();
	string[string] colors;

	void loadFrom(string path)
	{
		try
			foreach (line; readText(path).splitLines)
				if (auto m = line.matchFirst(ctRegex!(
					`^\s*([A-Za-z0-9_-]+)\s*=\s*"([^"]*)"`)))
					colors[m[1].idup] = m[2].idup;
		catch (Throwable)
		{
		}
	}

	auto home = environment.get("HOME", "");
	loadFrom("/usr/share/omarchy/themes/" ~ slug ~ "/colors.toml");
	loadFrom(home ~ "/.config/omarchy/themes/" ~ slug ~ "/colors.toml");

	colors["__theme"] = slug;
	return jsonEscapeObject(colors);
}

private string jsonEscape(string s)
{
	auto app = appender!string;
	app.put('"');
	foreach (char c; s)
	{
		if (c == '"')
			app.put("\\\"");
		else if (c == '\\')
			app.put("\\\\");
		else
			app.put(c);
	}
	app.put('"');
	return app.data;
}

private string jsonEscapeObject(string[string] kv)
{
	auto app = appender!string;
	app.put('{');
	bool first = true;
	foreach (k, v; kv)
	{
		if (!first)
			app.put(',');
		first = false;
		app.put(jsonEscape(k));
		app.put(':');
		app.put(jsonEscape(v));
	}
	app.put('}');
	return app.data;
}
