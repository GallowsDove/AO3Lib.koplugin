"""Compare conversion with the optional HTML/EPUB examples beside the repo.

Run from the plugin directory. Pass --epubcheck /path/to/epubcheck.jar for
formal EPUB validation. The reference files are user-provided, not fixtures.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

NS = {'o': 'http://www.idpf.org/2007/opf',
      'd': 'http://purl.org/dc/elements/1.1/',
      'h': 'http://www.w3.org/1999/xhtml',
      'n': 'http://www.daisy.org/z3986/2005/ncx/'}


def spine(package):
    items = {n.attrib['id']: n.attrib['href']
             for n in package.findall('./o:manifest/o:item', NS)}
    return [items[n.attrib['idref']]
            for n in package.findall('./o:spine/o:itemref', NS)], items


def normalize(text):
    return re.sub(r'\s+', ' ', text).strip()


def body_text(data):
    return ''.join(ET.fromstring(data).find('h:body', NS).itertext())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--epubcheck', type=Path)
    args = parser.parse_args()
    reference = Path('../Wish for a Bitch.epub')
    if not reference.exists() or not Path('../Wish for a Bitch.html').exists():
        print('SKIP: optional reference HTML/EPUB files are unavailable')
        return
    with tempfile.TemporaryDirectory(prefix='ao3-epub-reference-') as temp:
        output = Path(temp)
        (output / 'META-INF').mkdir()
        subprocess.run(['luajit', 'tests/test_html_epub.lua'], check=True,
                       env={**os.environ, 'AO3_EPUB_TEST_OUTPUT': temp})
        with zipfile.ZipFile(reference) as original:
            old = ET.fromstring(original.read('content.opf'))
            new = ET.parse(output / 'content.opf').getroot()
            for field in ('title', 'creator', 'language', 'description',
                          'publisher', 'subject', 'date'):
                assert ([n.text for n in old.findall('.//d:' + field, NS)] ==
                        [n.text for n in new.findall('.//d:' + field, NS)]), field
            old_spine, _ = spine(old)
            new_spine, items = spine(new)
            assert len(old_spine) == len(new_spine) == 4
            assert normalize(''.join(body_text(original.read(n)) for n in old_spine)) == normalize(
                ''.join(body_text((output / n).read_bytes()) for n in new_spine))
            old_nav = ET.fromstring(original.read('toc.ncx'))
            new_nav = ET.parse(output / 'toc.ncx').getroot()
            assert ([n.text for n in old_nav.findall('.//n:navLabel/n:text', NS)] ==
                    [n.text for n in new_nav.findall('.//n:navLabel/n:text', NS)])
        book = output / 'converted.epub'
        with zipfile.ZipFile(book, 'w') as archive:
            archive.writestr('mimetype', 'application/epub+zip',
                             compress_type=zipfile.ZIP_STORED)
            for name in dict.fromkeys(['META-INF/container.xml', 'content.opf',
                                      'toc.ncx', *items.values()]):
                if name.endswith(('.xml', '.opf', '.ncx', '.xhtml')):
                    ET.parse(output / name)
                archive.write(output / name, name, compress_type=zipfile.ZIP_DEFLATED)
        if args.epubcheck:
            subprocess.run(['java', '-jar', str(args.epubcheck), str(book)], check=True)
        print('PASS: reference metadata, complete text, four-part spine, NCX and XML')


if __name__ == '__main__':
    main()
