dofile('tests/test_network.lua')
local Fanfic=require('main')
local UI=require('ui/uimanager')
local History=require('ao3lib.library.history')
local work={id='52247068',path='/books/work.epub',title='A local work'}
require('ao3lib.library.epub').read=function(path)
    if path=='/broken.epub' then error('archive failed') end
    if path==work.path then return work end
end
local remembered=0
History.rememberLocal=function() error('Menu construction must not write history') end
History.load=function() end
for i=1,30 do
    local name,value=debug.getupvalue(Fanfic.init,i)
    if name=='FanficReader' then value.initializeFromReaderUI=function() end;break end
end
local FileManager={file_dialog_added_buttons={index={}}}
function FileManager:addFileDialogButtons(id,builder)
    self.file_dialog_added_buttons=self.file_dialog_added_buttons or {index={}}
    local rows=self.file_dialog_added_buttons
    if not rows.index[id] then rows[#rows+1]=builder;rows.index[id]=#rows end
end
package.loaded['apps/filemanager/filemanager']=FileManager
local owner=Fanfic:extend{ui={name='ReaderUI',menu={registerToMainMenu=function() end}},
    onDispatcherRegisterActions=function() end}
owner:init()
assert(#FileManager.file_dialog_added_buttons==1,'Reader-first initialization must register the class hook')
-- Exercise Bookshelf's actual plugin row collector with no FileManager instance.
local file=assert(io.open('../bookshelf.koplugin/lib/bookshelf_widget.lua'))
local source=file:read('*a');file:close()
local body=assert(source:match('(function BookshelfWidget:_fileDialogPluginRows%(file%)\n.-\nend)'))
local env=setmetatable({BookshelfWidget={}},{__index=_G})
local load=assert(loadstring(body));setfenv(load,env);load()
local collector=env.BookshelfWidget._fileDialogPluginRows
local rows=assert(collector({},work.path))
assert(rows[1][1].text=='Open AO3 work' and rows[1]._bs_id=='ao3_work_details')
assert(not collector({},'/ordinary.epub') and not collector({},'/broken.epub'))
assert(not FileManager.file_dialog_added_buttons[1](work.path,false))
-- A later host may own its own registry. Re-register without duplicating, and
-- ensure callbacks use the current plugin instance rather than the old reader.
FileManager.instance=setmetatable({file_dialog_added_buttons={index={}}},{__index=FileManager})
local current=Fanfic:extend{ui=FileManager.instance}
local opened
current.onShowFanficBrowser=function(_,works,fetch,title,options)
    opened={works=works,title=title,options=options};assert(fetch==nil)
end
current:registerWorkDetailsAction();current:registerWorkDetailsAction()
assert(#FileManager.file_dialog_added_buttons==1 and #FileManager.instance.file_dialog_added_buttons==1)
rows=assert(collector({},work.path))
History.rememberLocal=function(epub) remembered=remembered+1;return epub end
rows[1][1].callback()
assert(remembered==1 and opened.works[1].id==work.id and opened.title=='AO3 work details')
assert(opened.options.summary_html, 'Bookshelf work details must identify EPUB summaries as HTML')
assert(#FileManager.file_dialog_added_buttons==1,'The action identity must stay stable for Bookshelf action layouts')
print('PASS: actual Bookshelf action collection; reader-first startup; class/instance registries; stable ID; read-only menu building; current-owner callback; ordinary/corrupt books excluded')
