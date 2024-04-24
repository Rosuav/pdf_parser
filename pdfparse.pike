void parse_pdf(string file) {
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
	if (buf->sscanf("xref")) {write("%s: Has xref table\n", file); return;}
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
		if (mixed ex = catch (parse_pdf(file))) werror("Error parsing %s: %s\n", file, describe_backtrace(ex));
	}
}
