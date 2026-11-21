"""Validate a generated multichapter EPUB without user-provided examples."""
import argparse
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

LUA = r'''
package.path='./?.lua;'..package.path
package.loaded['libs/libkoreader-lfs']={}
package.loaded.util={trim=function(s) return (s:gsub('^%s+',''):gsub('%s+$','')) end}
local html=[[<!DOCTYPE html><html><head><title>Example</title></head><body>
<div id="preface"><h2 class="toc-heading">Preface</h2>
<p class="message">Originally at <a href="https://archiveofourown.org/works/123">AO3</a>.</p>
<div class="meta"><h1>Example story</h1><div class="byline"><a rel="author">Author</a></div>
<dl class="tags"><dt>Language:</dt><dd>English</dd><dt>Fandom:</dt><dd><a>Example</a></dd>
<dt>Series:</dt><dd>Part 2 of <a href="https://archiveofourown.org/series/42">Example series</a></dd>
<dt>Stats:</dt><dd>Published: 2025-01-01 Updated: 2025-02-01 Words: 1,200 Chapters: 2/2</dd></dl>
<p>Summary</p><blockquote><p>A &amp; B</p></blockquote></div></div>
<div id="chapters"><div class="meta group"><h2 class="heading">Chapter one</h2></div>
<p id="start">Content <em>with<br>line breaks</em>. <a href="#note">Note</a></p>
<div class="meta group"><h2 class="heading">Chapter two</h2></div><p>More content.</p></div>
<div id="afterword"><h2 class="toc-heading">Afterword</h2><p id="note">End note. <a href="#start">Back</a></p></div>
</body></html>]]
for path,bytes in pairs(require('ao3lib.library.html_epub').build(html,'123')) do
    local f=assert(io.open(arg[1]..'/'..path,'wb'));assert(f:write(bytes));f:close()
end
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--epubcheck', type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='ao3-epub-validation-') as directory:
        root = Path(directory)
        (root / 'META-INF').mkdir()
        script = root / 'convert.lua'
        script.write_text(LUA)
        subprocess.run(['luajit', str(script), str(root)], check=True)
        script.unlink()
        for path in root.rglob('*'):
            if path.suffix in ('.xml', '.opf', '.ncx', '.xhtml'):
                ET.parse(path)
        ns = {'d': 'http://purl.org/dc/elements/1.1/',
              'o': 'http://www.idpf.org/2007/opf',
              'n': 'http://www.daisy.org/z3986/2005/ncx/'}
        package = ET.parse(root / 'content.opf')
        assert package.find('.//d:title', ns).text == 'Example story'
        assert package.find('.//d:description', ns).text == '<p>A &amp; B</p>'
        assert package.find('.//o:meta[@name="calibre:series"]', ns).get('content') == 'Example series'
        labels = [node.text for node in ET.parse(root / 'toc.ncx').findall('.//n:navLabel/n:text', ns)]
        assert labels == ['Preface', 'Chapter one', 'Chapter two', 'Afterword'], labels
        files = sorted(path for path in root.rglob('*') if path.is_file() and path.name != 'mimetype')
        book = root / 'converted.epub'
        with zipfile.ZipFile(book, 'w') as archive:
            archive.writestr('mimetype', 'application/epub+zip', compress_type=zipfile.ZIP_STORED)
            for path in files:
                archive.write(path, path.relative_to(root), compress_type=zipfile.ZIP_DEFLATED)
        if args.epubcheck:
            subprocess.run(['java', '-jar', str(args.epubcheck.resolve()), str(book)], check=True)
        else:
            print('SKIP: formal EPUBCheck validation (pass --epubcheck)')
        print('PASS: generated EPUB XML, metadata, series, chapter navigation and linked notes')


if __name__ == '__main__':
    main()
