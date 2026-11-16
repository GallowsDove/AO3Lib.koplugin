"""Run: python -m unittest discover -s tests -p test_cleanup_epub.py"""
from pathlib import Path
import sys
import tempfile
import unittest
from zipfile import ZipFile, ZIP_DEFLATED, ZIP_STORED

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from cleanup_ao3_epub import clean_document, clean_epub, invariants, parse


def document(body):
    return ('''<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter</title></head>
<body><div id="chapters"><div class="userstuff">''' + body +
            '</div></div></body></html>').encode()


class CleanupTests(unittest.TestCase):
    def clean(self, body, preserve=True, classes=None):
        original = document(body)
        output, stats = clean_document(original, classes or {"message", "verse"}, preserve)
        self.assertEqual(invariants(parse(original).getroot()), invariants(parse(output).getroot()))
        return parse(output), stats, output

    def test_split_inline_styles_links_and_ids(self):
        tree, stats, _ = self.clean('<p id="p"><em id="em">A<br/><br/>B'
                                   '<a id="link" href="#target">C<br/><br/>D</a>E</em>F</p>'
                                   '<p id="target">Target</p>')
        paragraphs = tree.xpath('//*[local-name()="p"]')
        self.assertEqual(['A', 'BC', 'DEF', 'Target'], [''.join(p.itertext()) for p in paragraphs])
        self.assertEqual(2, stats['break_runs_converted'])
        self.assertEqual(1, len(tree.xpath('//*[@id="em"]')))
        self.assertEqual(1, len(tree.xpath('//*[@id="link"]')))
        self.assertEqual(['#target', '#target'], tree.xpath('//*[local-name()="a"]/@href'))

    def test_single_breaks_and_anchored_breaks_preserved(self):
        _, stats, _ = self.clean('<p>A<br/>B</p><p>C<br id="anchor"/><br/>D</p>')
        self.assertNotIn('break_runs_converted', stats)

    def test_blank_paragraphs_nbsp_and_media(self):
        tree, stats, _ = self.clean('<p>A</p><p>\u00a0</p><p><span> </span></p>'
                                   '<p>B</p><p><img src="art.png" alt="Art"/></p><p id="keep"> </p>')
        self.assertEqual(1, stats['blank_paragraphs_removed'])
        self.assertEqual(1, stats['possible_scene_gaps_retained'])
        self.assertEqual(1, len(tree.xpath('//*[@id="keep"]')))
        self.assertEqual(1, len(tree.xpath('//*[local-name()="img"]')))

    def test_normalize_mode_removes_redundant_gaps(self):
        tree, stats, _ = self.clean('<p>A<br/><br/><br/><br/>B</p><p>\u00a0</p>'
                                   '<p> </p><p>C</p>', preserve=False)
        self.assertEqual(0, stats.get('possible_scene_gaps_retained', 0))
        self.assertEqual(['A', 'B', 'C'], [''.join(p.itertext()) for p in tree.xpath('//*[local-name()="p"]')])

    def test_scene_gaps_and_leading_trailing_breaks(self):
        tree, stats, output = self.clean('<p><br/><br/><br/><br/>A<br/><br/><br/><br/>B'
                                         '<br/><br/><br/><br/></p>')
        self.assertEqual(1, stats['possible_scene_gaps_retained'])
        paragraphs = tree.xpath('//*[local-name()="p"]')
        self.assertEqual(['A', '\u00a0', 'B'], [''.join(p.itertext()) for p in paragraphs])
        again, _ = clean_document(output, set())
        self.assertEqual(output, again, 'cleanup must be idempotent')

    def test_formatted_blocks_notes_and_metadata_are_untouched(self):
        _, stats, output = self.clean('<p class="message">A<br/><br/>B</p>'
                                     '<blockquote><p>C<br/><br/>D</p></blockquote>'
                                     '<pre>E\n\nF</pre><p class="verse">G<br/><br/>H</p>'
                                     '<div id="endnotes"><p>I<br/><br/>J</p></div>'
                                     '<p style="background-image: url(art.png)"> </p>')
        self.assertNotIn('break_runs_converted', stats)
        self.assertEqual(document('<p class="message">A<br/><br/>B</p>'
                                 '<blockquote><p>C<br/><br/>D</p></blockquote>'
                                 '<pre>E\n\nF</pre><p class="verse">G<br/><br/>H</p>'
                                 '<div id="endnotes"><p>I<br/><br/>J</p></div>'
                                 '<p style="background-image: url(art.png)"> </p>'), output)

    def test_epub_output_preserves_other_entries_and_refuses_overwrite(self):
        with tempfile.TemporaryDirectory() as folder:
            source, dest = Path(folder)/'original.epub', Path(folder)/'clean.epub'
            container = b'<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>'
            package = b'<package><metadata><publisher>Archive of Our Own</publisher></metadata></package>'
            with ZipFile(source, 'w', compression=ZIP_DEFLATED) as z:
                z.writestr('mimetype', 'application/epub+zip', compress_type=ZIP_STORED)
                z.writestr('META-INF/container.xml', container)
                z.writestr('book.opf', package)
                z.writestr('chapter.xhtml', document('<p>A<br/><br/>B</p>'))
                z.writestr('styles.css', 'p { margin: 1em 0; }')
                z.writestr('toc.ncx', '<ncx/>')
            before = source.read_bytes()
            report = clean_epub(source)
            self.assertEqual(1, report['documents_changed'])
            self.assertFalse(dest.exists())
            clean_epub(source, dest)
            self.assertEqual(before, source.read_bytes())
            with ZipFile(source) as old, ZipFile(dest) as new:
                self.assertEqual(old.namelist(), new.namelist())
                self.assertEqual(ZIP_STORED, new.infolist()[0].compress_type)
                for name in old.namelist():
                    if name != 'chapter.xhtml':
                        self.assertEqual(old.read(name), new.read(name))
            self.assertEqual(0, clean_epub(dest)['documents_changed'])
            with self.assertRaises(FileExistsError):
                clean_epub(source, dest)
            with self.assertRaises(ValueError):
                clean_epub(source, source)


if __name__ == '__main__':
    unittest.main()
