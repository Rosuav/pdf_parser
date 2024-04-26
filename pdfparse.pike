mapping args;

Parser.LR.Parser parser = Parser.LR.GrammarParser.make_parser_from_file("pdf.grammar");
void throw_errors(int level, string subsystem, string msg, mixed ... args) {if (level >= 2) error(msg, @args);}

//This is a horrible breach of encapsulation. It might be necessary to instantiate something and have a dedicated handler object.
mapping last_dict;

mixed taketwo(mixed _, mixed val) {return val;}
mapping savedict(mixed _, mapping val) {return last_dict = val;}
mapping emptydict() {return ([]);}
mapping makedict(mixed key, mixed val) {return ([key: val]);}
mapping addtodict(mapping dict, mixed key, mixed val) {dict[key] = val; return dict;}
array emptyarray() {return ({});}
array makearray(mixed val) {return ({val});}
array appendarray(array arr, mixed val) {return arr + ({val});}

mapping makeobj(int oid, int gen, string _1, mapping info, string|void _2, string|void data, string|void _3) {
	if (data) {
		foreach (Array.arrayify(info->Filter), string filter) switch (filter) {
			case "FlateDecode":
				//TODO: DecodeParms may specify a Predictor
				data = Gz.uncompress(data);
				break;
			case "DCTDecode": error("UNIMPL - Image: %O\n", Image.JPEG.decode(data));
			default: break; //If unknown, leave it raw
		}
		info->_stream = data;
	}
	info->_oid = oid;
	return info;
}

mapping parse_pdf_object(string|Stdio.Buffer data) {
	if (stringp(data)) data = Stdio.Buffer(data);
	data->read_only();
	parser->set_error_handler(throw_errors);
	int streammode;
	array|string _next() {
		if (!sizeof(data)) error("BROKEN PDF: Unexpected end of file\n");
		if (streammode) {
			//NOTE: The "stream" keyword sets this flag, and then savedict() above should be called.
			//This will give us a reference to the dict-before-stream in last_dict.
			streammode = 0;
			return ({"streamdata", data->read(last_dict->Length)});
		}
		data->match("%*[\0\t\f \r\n]"); //Ignore whitespace
		while (data->match("%%%[^\r\n]%*[\0\t\f \r\n]")) ; //Ignore comments (with trailing whitespace)
		if (string delim = data->match("%1[][{}]")) return delim; //Delimiters are themselves unique tokens.
		if (array num = data->sscanf("%[+-]%[0-9.]")) {
			if (sizeof(num[0]) > 1) error("BROKEN PDF: Cannot have multiple signs on a number\n");
			if (num[1] == "") error("BROKEN PDF: Sign without number following it\n");
			//There should only be one dot in a float, too, but I can't be bothered checking
			if (has_value(num[1], '.')) return ({"real", (float)(num[0] + num[1])});
			//So. Um. If you have an int, then an int (usually zero), then the letter "R",
			//it's an object reference, NOT an integer. Ain't PDFs fun? See extra handling
			//below in next() for how this gets coped with.
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
		if (data->match("<")) {
			if (data->match("<")) return "<<";
			//Otherwise it's a hex string.
			string hex = data->match("%[^>]>");
			if (sizeof(hex) & 1) hex += "0"; //According to the spec, if there's an odd number of digits, an implicit last digit of zero is added. Kinda weird but okay.
			return ({"string", String.hex2string(hex)}); //Note that whitespace MIGHT be permitted within a byte, but Pike will reject it.
		}
		if (data->match(">>")) return ">>";
		string word = data->match("%[^][()<>{}/%\0\t\f \r\n]");
		if (word == "") error("BROKEN PDF: Unexpected token %O\n", data->read(10));
		if (word == "stream") {
			streammode = 1;
			data->match("%[\r]\n"); //After the "stream" keyword, there is an EOL that must be CRLF or LF, but not CR.
		}
		if (word == "endobj") return ""; //The endobj token terminates parsing.
		if (word == "true") return ({"value", Val.true});
		if (word == "false") return ({"value", Val.false});
		if (word == "null") return ({"value", Val.null});
		return word; //All other words are considered keywords.
	}
	array unread = ({ });
	array|string next() {
		//Handle object references, which don't fit an LALR(1) grammar due to requiring two-token lookahead
		if (sizeof(unread) == 2 && unread[1][0] == "int") {
			//It's a sequence of integers. Grab another token and see if it's an
			//object reference, otherwise keep going.
			array|string third = _next();
			if (third == "R") {
				array ret = ({"reference", ({unread[*][1]})});
				unread = ({ });
				return ret;
			}
			unread += ({third});
			//Otherwise, we'll move one off unread and yield it.
		}
		if (sizeof(unread)) {
			[array|string ret, unread] = Array.shift(unread);
			return ret;
		}
		array|string tok = _next();
		if (arrayp(tok) && tok[0] == "int") {
			unread = ({_next()});
			if (arrayp(unread[0]) && unread[0][0] == "int") {
				unread += ({_next()});
				//If the third token from this one is the "R", we have a single object reference
				if (unread[1] == "R") {
					tok = ({"reference", ({tok[1], unread[0][1]})});
					unread = ({ });
				}
				//Otherwise, handling above will take care of sequences of integers.
			}
		}
		return tok;
	}
	//array|string shownext() {array|string ret = next(); werror("TOKEN: %O\n", ret); return ret;}
	//while (shownext() != ""); return 0; //Dump tokens w/o parsing
	return parser->parse(next, this);
}

mapping(string:array|mapping) parse_xref_stream(string data, object buf) {
	mapping xref = parse_pdf_object(buf);
	array ret = ({ });
	if (xref->Prev) ret = parse_xref_stream(data, Stdio.Buffer(data[xref->Prev..]))->objects;
	//The xref data consists of a number of entries of fixed size.
	//Each entry is one of:
	//({0, next, gen}) - free list entry (this OID is free, as is the next one) (closed loop??)
	//({1, ofs, gen}) - uncompressed objects
	//({2, oid, idx}) - compressed objects, referenced by another OID
	int need = max(xref->Size, xref->_oid + 1) - sizeof(ret); //HACK: Cope with broken PDF - if our OID is beyond the stated size, allow room for it.
	if (need > 0) ret += ({0}) * need;
	ret[xref->_oid] = xref;
	//The entries are all tuples of three integers, the sizes of which are defined by the W array.
	string fmt = sprintf("%%%dc%%%dc%%%dc%%s", @xref->W);
	string entries = xref->_stream;
	if (!xref->Index) xref->Index = ({0, xref->Size});
	foreach (xref->Index / 2, [int start, int len]) {
		for (int oid = start; oid < start + len; ++oid) {
			if (oid == xref->_oid) continue; //Already got ourselves
			sscanf(entries, fmt, int type, int x, int y, entries);
			if (!xref->W[0]) type = 1; //If types are omitted, they are to be assumed to be 1 (uncompressed object).
			ret[oid] = ({type, x, y});
			//To fully decode a type 1: ret[oid] = parse_pdf_object(Stdio.Buffer(data[ret[oid][1]..]))
			//To fully decode a type 2: First ensure that ret[ret[oid][1]] exists
		}
	}
	return (["ID": xref->ID, "Root": xref->Root, "objects": ret]);
}

mixed get_indirect_object(string data, array objects, int oid) {
	if (mappingp(objects[oid])) return objects[oid];
	if (!arrayp(objects[oid])) error("Unknown OID slot\n");
	[int type, int x, int y] = objects[oid];
	switch (type) {
		default: //Unknown or free list entry, just null.
		case 0: return objects[oid] = Val.null;
		case 1: return objects[oid] = parse_pdf_object(Stdio.Buffer(data[x..]));
		case 2: {
			//Compressed object. First, we need to get the object that contains it.
			mapping parent = get_indirect_object(data, objects, x);
			if (!parent->_contents) {
				//So... officially, what we do is:
				//1. Parse off the first parent->First bytes, which is a stream of pairs of integers
				//2. Take the n'th int pair, which should be [oid, ofs] with the correct oid
				//3. Start at offset (parent->First+ofs) in the decompressed _stream
				//4. Read one value, which is usually a <<dict>> but might be anything (other than an objref)
				//What we ACTUALLY do is:
				//1. Ignore the first parent->First bytes
				//2. Wrap the entire rest of the stream in an array
				//3. Assume there's no junk anywhere, and assume that there's precisely one object per slot
				//4. Return the object at that slot.
				//According to the spec, the offsets MUST increase as we progress through the slots.
				//(Note that this does not have to be in OID order.) Assuming that no encoder will put
				//arbitrary junk between the values (other than whitespace which is ignored), this
				//simplified decoding method should work.
				parent->_contents = parse_pdf_object("[" + parent->_stream[parent->First..] + "] endobj");
			}
			return parent->_contents[y];
		}
	}
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
	write("File: %s\n", file);
	if (buf->sscanf("xref")) {write("Has xref table\n"); return;} //Might need a different grammar
	mapping xref = parse_xref_stream(data, buf);
	mapping root = get_indirect_object(data, xref->objects, xref->Root[0]);
	//Possibly interesting: root->AcroForm, root->Metadata
	//Definitely interesting: root->DSS
	if (root->DSS) {
		//Document might be signed digitally
		//DSS: Document Security Store
		//DSS->VRI: Validation Related Information (probably irrelevant)
		//DSS->Certs: Array of certificate objects
		//DSS->CRLs: Array of revocations (should we check these?)
		mapping dss = get_indirect_object(data, xref->objects, root->DSS[0]);
		if (dss->Certs) {
			array certs = get_indirect_object(data, xref->objects, dss->Certs[0]);
			foreach (certs, [int oid, int gen]) {
				string cert = get_indirect_object(data, xref->objects, oid)->_stream;
				//werror("Cert: %O\n", Standards.X509.decode_certificate(cert));
			}
		}
		//Certs are all well and good, but how do we locate the signature? What refers to it?
		//There seems to be root->Pages->Kids[*]->Annots[*]->V which has Type: Sig
		foreach (get_indirect_object(data, xref->objects, root->Pages[0])->Kids, array kid) {
			mapping page = get_indirect_object(data, xref->objects, kid[0]);
			if (page->Annots) foreach (page->Annots, [int anno, int gen]) {
				object annot = get_indirect_object(data, xref->objects, anno);
				object V = get_indirect_object(data, xref->objects, annot->V[0]); //Is it always present?
				if (V->Type == "Sig") write("Appears to have digital signature!\n");
			}
		}
	}
	if (args->i) {
		werror("Root: %O\n", root);
		while (1) {
			string oid = Stdio.stdin->gets(); if (!oid) break;
			werror("%O\n", get_indirect_object(data, xref->objects, (int)oid));
		}
	}
}

int main(int argc, array(string) argv) {
	//werror("Parse result: %O\n", parse_pdf_object(Stdio.read_file(argv[1])[94940..])); return 0;
	args = Arg.parse(argv);
	if (!sizeof(args[Arg.REST])) {
		exit(1, "Usage: pike " + argv[0] + " <file> <file> ...\n");
	}
	foreach (args[Arg.REST], string file) {
		if (mixed ex = catch (parse_pdf_file(file))) werror("Error parsing %s: %s\n", file, describe_backtrace(ex));
	}
}
