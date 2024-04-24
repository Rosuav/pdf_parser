Parser.LR.Parser parser = Parser.LR.GrammarParser.make_parser_from_file("pdf.grammar");
void throw_errors(int level, string subsystem, string msg, mixed ... args) {if (level >= 2) error(msg, @args);}

mixed taketwo(mixed _, mixed val) {return val;}
mapping emptydict() {return ([]);}
mapping makedict(mixed key, mixed val) {write("Make dict: %O %O\n", key, val); return ([key: val]);}
mapping addtodict(mapping dict, mixed key, mixed val) {dict[key] = val; return dict;}
array emptyarray() {return ({});}
array makearray(mixed val) {return ({val});}
array appendarray(array arr, mixed val) {return arr + ({val});}

mapping makeobjstream(int oid, int gen, string type, mapping info, string raw) {
	//TODO: Decode?
	return (["oid": oid, "type": type, "info": info, "raw": raw]);
}

mapping parse_pdf(string|Stdio.Buffer data) {
	if (stringp(data)) data = Stdio.Buffer(data);
	data->read_only();
	parser->set_error_handler(throw_errors);
	array|string next() {
		if (!sizeof(data)) return "";
		data->match("%*[\0\t\f \r\n]"); //Ignore whitespace
		while (data->match("%%%[^\r\n]%*[\0\t\f \r\n]")) ; //Ignore comments (with trailing whitespace)
		if (string delim = data->match("%1[][{}]")) return delim; //Delimiters are themselves unique tokens.
		if (array num = data->sscanf("%[+-]%[0-9.]")) {
			if (sizeof(num[0]) > 1) error("BROKEN PDF: Cannot have multiple signs on a number\n");
			if (num[1] == "") error("BROKEN PDF: Sign without number following it\n");
			//There should only be one dot in a float, too, but I can't be bothered checking
			if (has_value(num[1], '.')) return ({"real", (float)(num[0] + num[1])});
			return ({"int", (int)(num[0] + num[1])});
		}
		if (data->match("(")) {
			//String literal (non-hex)
			string value = "";
			int parens = 0;
			while (sizeof(data)) {
				if (string easy = data->match("%[^()\\]")) value += easy;
				if (data->match("(")) {value += "("; ++parens;}
				if (data->match(")"))
					if (parens) {value += ")"; --parens;}
					else break; //End of string.
				if (data->match("\\")) {
					//Backslash escapes
					if (data->match("%[\r\n]")) continue; //Backslash followed by EOL is ignored (cheat: I'm ignoring any number of newline/carriage return characters here)
					if (data->match("n")) value += "\n";
					if (data->match("r")) value += "\r";
					if (data->match("t")) value += "\t";
					if (data->match("b")) value += "\b";
					if (data->match("f")) value += "\f";
					if (data->match("(")) value += "(";
					if (data->match(")")) value += ")";
					if (data->match("\\")) value += "\\";
					if (array octal = data->sscanf("%3o")) value += (string)({octal[0]});
				}
			}
			return ({"string", value});
		}
		if (data->match("/")) {
			string value = "";
			while (sizeof(data)) {
				if (string easy = data->match("%[^][()<>{}/%\0\t\f \r\n#]")) value += easy;
				if (array hex = data->sscanf("#%2x")) value += (string)({hex[0]});
				else break; //A name ends at the first delimiter character
			}
			//NOTE: Names should be interpreted as UTF-8. (Should we decode to Unicode here?)
			//NOTE: There is one example ("Lime Green") in https://opensource.adobe.com/dc-acrobat-sdk-docs/pdfstandards/PDF32000_2008.pdf
			//which appears to casefold, at least the first character. I am assuming for now that
			//this is an error in the example, and performing no case folding.
			return ({"name", value});
		}
		if (data->match("<<")) return "<<";
		if (data->match(">>")) return ">>";
		//TODO: Hex strings (single "<" and ">")
		string word = data->match("%[^][()<>{}/%\0\t\f \r\n]");
		if (word == "") error("BROKEN PDF: Unexpected token %O\n", data->read(10));
		if (word == "stream") {
			error("UNIMPL\n");
		}
		if (word == "true") return ({"value", Val.true});
		if (word == "false") return ({"value", Val.false});
		if (word == "null") return ({"value", Val.null});
		return ({"word", word});
	}
	array|string shownext() {array|string ret = next(); werror("TOKEN: %O\n", ret); return ret;}
	while (shownext() != ""); return 0; //Dump tokens w/o parsing
	return parser->parse(next, this);
}

void parse_pdf_file(string file) {
	string f = Stdio.read_file(file);
	array parts = f / "%%EOF";
	string data = parts[.. < 1] * "%%EOF";
	array lastlines = replace(replace(data[<64..], "\r\n", "\n"), "\r", "\n") / "\n";
	// assert lastlines[-1] == "";
	// assert lastlines[-3] == "startxref" or "startxref\r";
	int startxref = (int) lastlines[-2];
	// byte position at which data begins. (probably Root object)
	object buf = Stdio.Buffer(data[startxref..]);
	//This will start with either an xref table or an xref stream.
	if (buf->sscanf("xref")) {write("%s: Has xref table\n", file); return;} //Might need a different grammar
	mapping info = parse_pdf(buf);
	write("%s: Parse result %O\n", file, info);
	array strm = buf->sscanf("%d %d obj%[\r\n]<<");
	if (!strm || sizeof(strm) < 3 || strm[2] == "") {write("%s: ERROR: Malformed xref stream\n", file); return;}
	write("%s: Has xref stream [%d %d]\n", file, strm[0], strm[1]);
	//strm[0] is the object ID, strm[1] is the generation(?) - should always be zero (?)
	mapping strmdict = ([]);
	while (array entry = buf->sscanf("%[^\r\n ] %[^\r\n]%[\r\n]")) {
		werror("Entry: %O\n", entry);
		strmdict[entry[0]] = entry[1];
	}
	write("%s: Stream dictionary %O\n%[0]s: Next bytes: %q\n", file, strmdict, buf->read(16));
}

int main(int argc, array(string) argv) {
	mapping args = Arg.parse(argv);
	if (!sizeof(args[Arg.REST])) {
		exit(1, "Usage: pike " + argv[0] + " <file> <file> ...\n");
	}
	foreach (args[Arg.REST], string file) {
		if (mixed ex = catch (parse_pdf_file(file))) werror("Error parsing %s: %s\n", file, describe_backtrace(ex));
	}
}
