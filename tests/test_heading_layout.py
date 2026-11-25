"""Check the real KOReader MuPDF layout when its desktop runtime is available."""
from pathlib import Path
import os
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
KOREADER = Path(os.environ.get('KOREADER_DIR', '/usr/lib/koreader'))


class HeadingLayout(unittest.TestCase):
    @unittest.skipUnless((KOREADER / 'luajit').is_file() and (KOREADER / 'ffi/mupdf.lua').is_file(),
                         'KOReader MuPDF runtime is not installed')
    def test_heading_uses_available_width_and_stays_next_to_badges(self):
        script = r'''
require('ffi/loadlib')
local root=os.getenv('AO3_TEST_ROOT')..'/'
package.path=root..'?.lua;'..package.path
package.loaded.gettext=function(s) return s end
package.loaded['ao3lib.bookshelf.metadata']={fromWork=function() return {ao3_completion={'complete'}} end}
package.loaded['ao3lib.bookshelf.badges']={symbols=function() return {'x','x','x','x'} end,
    relativePath=function() return 'ao3-icons/rating-general-audience.png' end}
local view=require('ao3lib.ui.work_view')
local mupdf=require('ffi/mupdf')
local function check(title,author,fandom,width)
    local body=view.html({id=1,title=title,author=author,fandoms={fandom}},
        {{title,callback=function() end},{'Author:',author,callback=function() end}},
        {tag_action=function() end})
    local doc=mupdf.openDocumentFromText('<html><head><style>'..view.css..'</style></head><body>'..body..'</body></html>',
        'html',root..'assets/')
    doc:layoutDocument(width,800,20)
    local links=doc:openPage(1):getPageLinks()
    local boxes={}
    for _,box in ipairs(links) do
        boxes[box.uri]=boxes[box.uri] or {};table.insert(boxes[box.uri],box)
    end
    for _,id in ipairs({'ao3-action:1','ao3-action:2','ao3-action:3'}) do
        assert(boxes[id] and #boxes[id]==1,id..' unexpectedly wraps at '..width..'px')
    end
    assert(boxes['ao3-action:1'][1].x0>=80 and boxes['ao3-action:1'][1].x0<=100,
        'The title must start beside the badge, not in the middle')
    assert(boxes['ao3-action:3'][1].x0==boxes['ao3-action:1'][1].x0,
        'The fandom and title must share the same left edge')
end
-- This title previously wrapped with a shrink-to-fit table at 350px.
check('A thousand little things','A','A',350)
for _,width in ipairs({400,600,1000}) do
    check('Short title','Jane Doe','Example fandom',width)
    check('✓ Short title','Jane Doe','Example fandom',width)
end
'''
        result = subprocess.run([str(KOREADER / 'luajit'), '-e', script],
                                cwd=KOREADER, text=True, capture_output=True,
                                env={**os.environ, 'AO3_TEST_ROOT': str(ROOT)})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
