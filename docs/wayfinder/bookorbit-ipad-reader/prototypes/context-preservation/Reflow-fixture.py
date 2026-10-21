from pathlib import Path
import hashlib
import json
import zipfile

root = Path(__file__).resolve().parent
output = root / "Fixtures/Reflow/reflow.epub"
titles = ["A word grows", "A sentence wraps", "A narrower page", "Ink follows a page turn", "Edit the earlier handwriting", "Add a second note", "Choose the intended words", "Several notes share a margin", "A note returns"]
files = {
    "mimetype": b"application/epub+zip",
    "META-INF/container.xml": b'<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
    "OEBPS/SourceSerif4-Regular.otf": (root / "Fixtures/EPUB/OEBPS/SourceSerif4-Regular.otf").read_bytes(),
    "OEBPS/style.css": b'@font-face{font-family:Sample;src:url("SourceSerif4-Regular.otf")}body{font-family:Sample,Georgia,serif;line-height:1.6}h1{font-size:1.2em}p{margin:1em 0}img{max-width:100%}table{border-collapse:collapse}td{border:1px solid;padding:.3em}',
}
for index, title in enumerate(titles):
    paragraphs = [
        "The most useful observation keeps its original context. A small mark can bring an old idea back into focus.",
        "A different useful observation can lead down another path. The word appears again, but this sentence has its own meaning.",
        "There is room for another useful idea beside the first two. Some comments belong together; others only happen to be close.",
    ] + [f"Along the river, the reader stops at gate {n + 1}. The light changes across the water, and the notebook holds a few careful observations. A familiar sentence can look different on a smaller page, while its meaning stays the same." for n in range(18)]
    body = "".join(f"<p>{p}</p>" for p in paragraphs)
    body += '<p>English and العربية share a line. A useful thought includes café, é, ﬃ and 🌙.</p><table><tr><td>A useful table cell</td><td>A second observation</td></tr></table>'
    files[f"OEBPS/chapter{index}.xhtml"] = f'<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>{title}</title><link rel="stylesheet" href="style.css"/></head><body><h1>{title}</h1>{body}</body></html>'.encode()
manifest = ''.join(f'<item id="c{i}" href="chapter{i}.xhtml" media-type="application/xhtml+xml"/>' for i in range(len(titles)))
spine = ''.join(f'<itemref idref="c{i}"/>' for i in range(len(titles)))
files["OEBPS/nav.xhtml"] = ('<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol>' + ''.join(f'<li><a href="chapter{i}.xhtml">{title}</a></li>' for i,title in enumerate(titles)) + '</ol></nav></body></html>').encode()
files["OEBPS/package.opf"] = f'<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">bookorbit-reflow-prototype-1</dc:identifier><dc:title>Text-following ink: local samples</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">2026-10-20T00:00:00Z</meta></metadata><manifest>{manifest}<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="css" href="style.css" media-type="text/css"/><item id="font" href="SourceSerif4-Regular.otf" media-type="font/otf"/></manifest><spine>{spine}</spine></package>'.encode()
with zipfile.ZipFile(output, "w") as archive:
    for name, data in files.items():
        info = zipfile.ZipInfo(name, (2026, 10, 20, 0, 0, 0))
        info.compress_type = zipfile.ZIP_STORED if name == "mimetype" else zipfile.ZIP_DEFLATED
        archive.writestr(info, data)
(output.parent / "fixture-provenance.json").write_text(json.dumps({"source":"Self-authored local EPUB; no private library", "chapters":len(titles),"sha256":hashlib.sha256(output.read_bytes()).hexdigest(),"font":"Source Serif 4 Regular 4.005R; existing Fixtures/FONT-LICENSE.md", "rendererBaseline":"ce118e3890ea8c9019857cb7556552cdc9992f8e"}, indent=2)+"\n")
print(f"Built {output.name}: {output.stat().st_size} bytes, {len(titles)} chapters")
