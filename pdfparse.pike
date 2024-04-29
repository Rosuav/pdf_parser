mapping args;

//Inside other objects, there can be references to indirect objects.
class ObjectReference(int oid, int gen) {
	constant is_reference = 1;
	protected string _sprintf(int type) {return type == 'O' && sprintf("ObjectReference(%d, %d)", oid, gen);}
}

//In the xref table/stream, there can be references to either uncompressed or compressed objects.
//During decoding, some of these will be replaced with non-references, allowing faster repeated lookups.
class UncompressedObjectReference(int ofs, int gen) {
	constant is_reference = 1, is_uncompressed = 1;
	protected string _sprintf(int type) {return type == 'O' && sprintf("UncompressedObjectReference(%d, %d)", ofs, gen);}
}

class CompressedObjectReference(int container, int idx) {
	constant is_reference = 1, is_compressed = 1;
	protected string _sprintf(int type) {return type == 'O' && sprintf("CompressedObjectReference(%d, %d)", container, idx);}
}

typedef mapping|array|string|int|float|Val.Null pdf_value;
typedef pdf_value|ObjectReference|UncompressedObjectReference|CompressedObjectReference pdf_reference;

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

mapping makeobj(int oid, int gen, string _1, pdf_value info) {return info;}

mapping makestreamobj(int oid, int gen, string _1, mapping info, string|void _2, string|void data, string|void _3) {
	if (data) {
		foreach (Array.arrayify(info->Filter), string filter) switch (filter) {
			case "FlateDecode": {
				data = Gz.uncompress(data);
				//After the deflation, reapply the predictor's predictions...
				//... most of which I don't yet support.
				switch (info->DecodeParms->?Predictor) {
					case 12: { //PNG "Up". Others could be done the same way.
						//The "Up" predictor subtracts this row from the previous, and
						//importantly, prepends a "\2" to each row.
						array rows = data / (info->DecodeParms->Columns + 1);
						array prev = ({0}) * info->DecodeParms->Columns;
						string out = "";
						foreach (rows, string r) {
							array row = (((array)r[1..])[*] + prev[*])[*] % 256;
							prev = row;
							out += (string)row;
						}
						data = out;
						break;
					}
					//TODO: Add more predictors as we find them in the wild
					default: break;
				}
				break;
			}
			case "DCTDecode": error("UNIMPL - Image: %O\n", Image.JPEG.decode(data));
			default: break; //If unknown, leave it raw
		}
		info->_stream = data;
	}
	info->_oid = oid;
	return info;
}

pdf_value parse_pdf_object(string|Stdio.Buffer data) {
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
		if (word == "endobj" || word == "startxref") return ""; //These tokens terminate parsing.
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
				array ret = ({"reference", ObjectReference(@unread[*][1])});
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
					tok = ({"reference", ObjectReference(tok[1], unread[0][1])});
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

class PDF {
	string data; //Raw data read from the file
	array objects; //Full object list, parsed from the crossreference table (or stream)

	mapping(string:array|mapping) parse_xref_stream(object buf) {
		array table;
		if (buf->sscanf("xref")) {
			//It's an xref table rather than a stream.
			table = ({ });
			while (sizeof(buf)) {
				[int start, int len] = buf->sscanf("%d %d%*[\r\n]");
				string entries = buf->read(len * 20);
				if (sizeof(table) < start + len) table += ({0}) * (start + len - sizeof(table));
				for (int oid = start; oid < start + len; ++oid) {
					sscanf(entries, "%d %d %c%*[\r\n]%s", int ofs, int gen, int type, entries);
					if (type == 'n') table[oid] = UncompressedObjectReference(ofs, gen);
					else table[oid] = Val.null; //Free-list entries have "next" rather than offset, but we don't care here
				}
				if (buf->sscanf("%*[\r\n]trailer")) break;
			}
			//After the word "trailer" (which has now been consumed), there's a dictionary followed
			//by the word "startxref", which is defined in the tokenizer as a termination token.
		}
		mapping xref = parse_pdf_object(buf);
		array ret = ({ });
		if (xref->Prev) ret = parse_xref_stream(Stdio.Buffer(data[xref->Prev..]))->objects;
		//The xref data consists of a number of entries of fixed size.
		//Each entry is one of:
		//({0, next, gen}) - free list entry (this OID is free, as is the next one) (closed loop??)
		//({1, ofs, gen}) - uncompressed objects
		//({2, oid, idx}) - compressed objects, referenced by another OID
		int need = max(xref->Size, xref->_oid + 1) - sizeof(ret); //HACK: Cope with broken PDF - if our OID is beyond the stated size, allow room for it.
		if (need > 0) ret += ({0}) * need;
		if (xref->_oid) ret[xref->_oid] = xref;
		if (xref->_stream) {
			//The entries are all tuples of three integers, the sizes of which are defined by the W array.
			string fmt = sprintf("%%%dc%%%dc%%%dc%%s", @xref->W);
			string entries = xref->_stream;
			if (!xref->Index) xref->Index = ({0, xref->Size});
			foreach (xref->Index / 2, [int start, int len]) {
				for (int oid = start; oid < start + len; ++oid) {
					if (oid == xref->_oid) continue; //Already got ourselves
					sscanf(entries, fmt, int type, int x, int y, entries);
					if (!xref->W[0]) type = 1; //If types are omitted, they are to be assumed to be 1 (uncompressed object).
					switch (type) {
						case 0: ret[oid] = Val.null; break;
						case 1: ret[oid] = UncompressedObjectReference(x, y); break;
						case 2: ret[oid] = CompressedObjectReference(x, y); break;
					}
					//To fully decode a type 1: ret[oid] = parse_pdf_object(Stdio.Buffer(data[ret[oid][1]..]))
					//To fully decode a type 2: First ensure that ret[ret[oid][1]] exists... see deref()
				}
			}
		}
		if (table) {
			if (sizeof(table) > sizeof(ret)) ret += ({0}) * (sizeof(table) - sizeof(ret));
			foreach (table; int oid; mixed entry) if (entry) ret[oid] = entry; //Latest table always takes precedence over older ones.
		}
		return (["ID": xref->ID, "Root": xref->Root, "objects": ret]);
	}

	//Pass the oid to autocache back into that slot, otherwise not required
	pdf_value deref(pdf_reference obj, int|void oid) {
		if (!objectp(obj) || !obj->is_reference) return obj;
		if (obj->is_compressed) {
			//Compressed object. First, we need to get the object that contains it.
			mapping parent = deref(objects[obj->container], obj->container);
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
			return parent->_contents[obj->idx];
		}
		if (obj->is_uncompressed) {
			pdf_value ret = parse_pdf_object(Stdio.Buffer(data[obj->ofs..]));
			if (oid) objects[oid] = ret;
			return ret;
		}
		return deref(objects[obj->oid], obj->oid);
	}

	protected void create(string filename) {
		string f = Stdio.read_file(filename);
		array parts = f / "%%EOF";
		data = parts[.. < 1] * "%%EOF";
		array lastlines = replace(replace(data[<64..], "\r\n", "\n"), "\r", "\n") / "\n";
		// assert lastlines[-1] == "";
		// assert lastlines[-3] == "startxref" or "startxref\r";
		int startxref = (int) lastlines[-2];
		// byte position at which data begins. (probably Root object)
		object buf = Stdio.Buffer(data[startxref..]);
		//This will start with either an xref table or an xref stream.
		write("File: %s\n", filename);
		mapping xref = parse_xref_stream(buf);
		objects = xref->objects; //A lot of things will need this.
		mapping root = deref(xref->Root);
		//Possibly interesting: root->AcroForm, root->Metadata
		//Definitely interesting: root->DSS
		if (root->DSS) {
			//Document might be signed digitally
			//DSS: Document Security Store
			//DSS->VRI: Validation Related Information (probably irrelevant)
			//DSS->Certs: Array of certificate objects
			//DSS->CRLs: Array of revocations (should we check these?)
			mapping dss = deref(root->DSS);
			if (dss->Certs) {
				array certs = deref(dss->Certs);
				foreach (certs, pdf_reference c) {
					string cert = deref(c)->_stream;
					//werror("Cert: %O\n", Standards.X509.decode_certificate(cert));
				}
			}
			//Certs are all well and good, but how do we locate the signature? What refers to it?
			//There seems to be root->Pages->Kids[*]->Annots[*]->V which has Type: Sig
			foreach (deref(root->Pages)->Kids, array kid) {
				mapping page = deref(kid);
				if (page->Annots) foreach (page->Annots, pdf_reference anno) {
					object annot = deref(anno);
					object V = deref(annot->V); //Is it always present?
					if (V->Type == "Sig") write("Appears to have digital signature! %O\n", V->Cert && Standards.X509.decode_certificate(V->Cert));
				}
			}
		}
		mixed AcroForm = deref(root->AcroForm);
		if (mappingp(AcroForm)) foreach (AcroForm->?Fields || ({ }), pdf_reference anno) {
			mapping annot = deref(anno);
			mapping V = deref(annot->V); //Is it?
			if (V->Type == "Sig") write("Appears to have digital signature! %O\n", V->Cert && Standards.X509.decode_certificate(V->Cert));
		}
		if (args->i) {
			werror("Root: %O\n", root);
			pdf_value last = Val.null;
			while (1) {
				string cmd = Stdio.stdin->gets(); if (!cmd) break;
				if (int oid = (int)cmd) werror("%O\n", last = deref(objects[oid], oid));
				if (mappingp(last) && last[cmd]) werror("%O\n", last = last[cmd]);
				if (cmd == "X509" || cmd == "x509") {
					werror("%O\n", Standards.X509.decode_certificate(last));
					//Still not working. Not sure what the Contents is here but it does definitely contain certs.
					//What is "SubFilter": "adbe.pkcs7.detached"?
					string cert = last;
					for (int i = 1; i < sizeof(cert); ++i) {
						if (!catch {
							object buf = Stdio.Buffer(cert[i..]);
							Standards.ASN1.Decode.der_decode(buf, (mapping)Standards.ASN1.Decode.universal_types);
							werror("Residue: %O\n", sizeof(buf));
							if (mixed c = Standards.X509.decode_certificate(cert[i..<sizeof(buf)])) werror("%d..<%d: %O\n", i, sizeof(buf), c);
						}) break;
					}
				}
				if (cmd == "save") Stdio.write_file("raw.dump", last);
			}
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
		if (mixed ex = catch (PDF(file))) werror("Error parsing %s: %s\n", file, describe_backtrace(ex));
	}
}
