package om;

using StringTools;

enum EArgType {
	bool;
	float;
	int;
	string;
}

abstract ArgType(EArgType) from EArgType to EArgType {
	public function hint():String {
		return switch this {
			case bool:
				"";
			case string:
				"<string>";
			case int:
				"<int>";
			case float:
				"<float>";
		}
	}
}

@:structInit
class Def {
	public var name:String;
	public var shortName:String;
	public var type:ArgType;
	public var description:String;
	public var required:Bool;
	public var defaultValue:String;
	public var multiple:Bool;

	public function new(name:String, ?shortName:String, ?type:ArgType, ?description:String, required = false, ?defaultValue:String, multiple = false) {
		this.name = name;
		this.shortName = shortName;
		this.type = type ?? string;
		this.description = description;
		this.required = required;
		this.defaultValue = defaultValue;
		this.multiple = multiple;
	}

	public function validate(value:String):Bool
		return switch type {
			case int:
				switch Std.parseInt(value) {
					case null: false;
					case _: !value.contains(".");
				}
			case float: !Math.isNaN(Std.parseFloat(value));
			case bool:
				switch value {
					case null, "", "true", "false": true;
					case _: false;
				}
			case _: true;
		}
}

class Command {
	public final name:String;
	public final description:String;
	public final defs:Array<Def>;
	public final sub:Map<String, Command> = [];
	public final values:Map<String, Array<String>> = [];

	public function new(name:String, ?description:String, ?defs:Array<Def>, ?sub:Array<Command>) {
		this.name = name;
		this.description = description;
		this.defs = defs ?? [];
		if (sub != null)
			for (c in sub)
				add(c);
	}

	public function add(cmd:Command) {
		sub.set(cmd.name, cmd);
	}

	public function resolve(args:Array<String>):Command {
		if (args.length > 0) {
			if (isHelpFlag(args[0])) {
				Sys.println(help());
				Sys.exit(0);
			}
			final subcmd = sub.get(args[0]);
			if (subcmd != null)
				return subcmd.resolve(args.slice(1));
			else if (args[0].startsWith("--") || args[0].startsWith("-")) {
				// flags intended for current command, fall through
			} else if (sub.keys().hasNext())
				throw 'Unknown subcommand: ${args[0]}';
		}
		this.parse(args);
		return this;
	}

	public function parse(args:Array<String>) {
		final defMap = new Map<String, Def>();
		for (def in defs) {
			defMap.set(def.name, def);
			if (def.shortName != null)
				defMap.set(def.shortName, def);
		}
		var i = 0;
		while (i < args.length) {
			var arg = args[i];
			if (!arg.startsWith("--") && !arg.startsWith("-")) {
				throw 'Unexpected argument: $arg';
			}
			i++;
			arg = arg.startsWith("--") ? arg.substr(2) : arg.substr(1);
			final eq = arg.indexOf("=");
			final key = eq >= 0 ? arg.substr(0, eq) : arg;
			final val = eq >= 0 ? arg.substr(eq + 1) : null;
			if (isHelpFlag('--$key') || isHelpFlag('-$key')) {
				Sys.println(help());
				Sys.exit(0);
			}
			final def = defMap.get(key);
			if (def == null)
				throw 'Unknown argument: --$key';
			if (!values.exists(def.name))
				values.set(def.name, []);
			final result = parseValue(args, i - 1, val, def);
			values.set(def.name, values.get(def.name).concat(result.values));
			i += result.advance - 1;
		}
		// Check required args
		for (def in defs) {
			if (!values.exists(def.name)) {
				if (def.defaultValue != null)
					values.set(def.name, [def.defaultValue]);
				else if (def.required)
					throw 'Missing required argument: --${def.name}';
			}
		}
	}

	public inline function get(name:String):Null<String>
		return getAll(name)[0];

	public inline function getAll(name:String):Array<String>
		return values.get(name) ?? [];

	public inline function getInt(name:String):Null<Int>
		return Std.parseInt(get(name));

	public inline function getFloat(name:String):Null<Float>
		return Std.parseFloat(get(name));

	public inline function getBool(name:String):Bool
		return get(name) == "true";

	public function help(indent = "  "):String {
		var line = 'Usage: $name';
		final hasSub = sub.keys().hasNext();
		if (hasSub)
			line += ' <subcommand>';
		if (defs.length > 0)
			line += " [options]";
		var lines = [line];
		if (hasSub) {
			lines.push('\nSubcommands:');
			for (cmd in sub) {
				var str = '$indent${cmd.name}';
				if (cmd.description != null)
					str += ' - ${cmd.description}';
				lines.push(str);
			}
		}
		if (defs.length > 0) {
			lines.push('\nOptions:');
			var hasHelpFlag = false;
			final entries = defs.map(def -> {
				if (def.name == "help")
					hasHelpFlag = true;
				final flagPart = def.shortName != null ? '-${def.shortName}, --${def.name}' : '--${def.name}';
				final typeHint = def.type.hint();
				return {def: def, left: typeHint != "" ? '$flagPart $typeHint' : flagPart};
			});
			if (!hasHelpFlag) {
				entries.push({def: {name: null, description: "Show help for this command"}, left: '-h, --help'});
			}
			var maxLeftWidth = 0;
			for (e in entries)
				if (e.left.length > maxLeftWidth)
					maxLeftWidth = e.left.length;
			lines = lines.concat(entries.map(e -> {
				var desc = e.def.description ?? "";
				if (e.def.defaultValue != null)
					desc += ' (default: ${e.def.defaultValue})';
				if (e.def.required)
					desc += ' (required)';
				if (e.def.multiple)
					desc += ' (multiple allowed)';
				return '$indent${StringTools.rpad(e.left, " ", maxLeftWidth + 2)}$desc';
			}));
		}
		return lines.join('\n');
	}

	function parseValue(args:Array<String>, i:Int, inlineValue:Null<String>, def:Def):{values:Array<String>, advance:Int} {
		var collected:Array<String> = [];
		var advance = 1;
		if (inlineValue != null) {
			collected = splitMultiple(inlineValue);
		} else if (def.type == bool) {
			collected = ["true"];
		} else if (i + 1 >= args.length || args[i + 1].startsWith("-")) {
			throw 'Missing value for --${def.name}';
		} else {
			var j = i + 1;
			while (j < args.length && !args[j].startsWith("-")) {
				collected = collected.concat(splitMultiple(args[j]));
				j++;
				if (!def.multiple)
					break;
			}
			advance = j - i;
		}
		for (val in collected)
			if (!def.validate(val))
				throw 'Invalid ${def.type} for --${def.name}: $val';
		return {values: collected, advance: advance};
	}

	function splitMultiple(value:String):Array<String> {
		return value.split(",").map(v -> v.trim()).filter(v -> v != "");
	}

	function isHelpFlag(arg:String)
		return switch arg {
			case "--help", "-h": true;
			case _: false;
		}
}
