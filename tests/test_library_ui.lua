package.path='./?.lua;'..package.path
dofile('tests/test_network.lua')
local Menu=require('ao3lib.ui.menu')
local UI=require('ui/uimanager')
UI.setDirty=function() end
local visible=true
UI.isWidgetShown=function() return visible end
package.loaded['ui/widget/menu'].updateItems=function() end
package.loaded['ao3lib.ui.update_review_header']={new=function() return {update=function(self,model) self.model=model end} end}
local view_settings,rendered_setting
package.loaded['ao3lib.core.config'].saveSetting=function(_,key,value) if key=='downloaded_view' then view_settings=value end end
package.loaded['ao3lib.core.config'].readSetting=function(_,key,default) if key=='downloaded_view' then return view_settings end;if key=='downloaded_rendered_view' and rendered_setting~=nil then return rendered_setting end;if key=='fanfic_folder_path' then return '/books' end;return default end
package.loaded['apps/filemanager/filemanagerutil'].getHomeFolder=function() return '/home' end
package.loaded['ao3lib.library.discovery']={scan=function() error('Opening a downloaded library must not start a directory scan') end}
local snapshot,jobs=nil,{}
package.loaded['ao3lib.library.local_cache']={get=function() return snapshot end,
    load=function(roots,done,valid)
        assert(roots[1]=='/books' and roots[2]=='/home')
        local job={done=done,valid=valid,cancel=function(self) self.cancelled=true end}
        jobs[#jobs+1]=job;return job
    end,
    remove=function(_,id) if snapshot then snapshot[tostring(id)]=nil end end}
local History=require('ao3lib.library.history')
History.get=function(id)
    if id=='1' then return {chapter_data={{read=true}},read=true,last_accessed='2026-11-01'} end
    if id=='2' then return {chapter_data={{read=true},{read=true}},last_accessed='2026-11-21'} end
end
local opened
local plugin={ui={},onOpenFanficReader=function(_,_,work) opened=work end}
Menu.fanfic=plugin
local a={id='1',path='/books/1.epub',title='First',author='Writer',chapters='1/1',wordcount='12345',fandoms={'Fandom'}}
local b={id='2',path='/books/2.epub',title='Second',author='Writer, Other',chapters='3/3',wordcount='34567',fandoms={'Fandom', 'Other Fandom'}}
local c={id='3',path='/books/3.epub',title='Third',author='Other',chapters='1/?'}
local window=Menu:onViewDownloadedFanfics()
assert(window.title=='Downloaded Works' and #window.item_table==0 and window.library_model.notice:find('Loading',1,true))
local pending=jobs[#jobs]
snapshot={['1']=a,['2']=b,['3']=c};pending.done(snapshot)
assert(window.library_model.total==3 and #window.item_table==3)
local AccountActions=require('ao3lib.ui.work_account_actions')
local originalAccountShow=AccountActions.show
local heldWork
AccountActions.show=function(work) heldWork=work end
window.item_table[1].hold_callback()
assert(heldWork==window.item_table[1].work)
AccountActions.show=originalAccountShow
for _,row in ipairs(window.item_table) do assert(row.work,'Only work rows belong in the list') end
assert(window.item_table[1].text:find('12,345 words',1,true))
assert(window.item_table[1].text:find('First  —  by Writer · Read',1,true),
    'Title, author and reading status must stay distinct when Menu normalizes newlines')
assert(window.item_table[1].work.read and window.item_table[1].work.chapter_data[1].read)
assert(not window.item_table[1].text:find('chapters read',1,true),'Read works need no duplicate chapter count')
assert(window.item_table[2].text:find(' · 2/3 chapters read · 34,567 words',1,true))
assert(not window.item_table[2].text:find('Reading',1,true),'Chapter progress replaces the reading label')
assert(window.item_table[3].text:find(' · Unread',1,true) and not window.item_table[3].text:find('chapters read',1,true))
-- Simulate KOReader's natural flexible heights, including a wrapping row.
local NativeMenu=package.loaded['ui/widget/menu']
NativeMenu.setupItemHeights=function(self)
    for i,item in ipairs(self.item_table) do item.height=i==2 and 60 or 30 end
end
package.loaded['device'].screen={scaleBySize=function(_,n) return n end}
window.available_height=125
window:setupItemHeights()
assert(window.item_table[1].height==36 and window.item_table[2].height==66)
assert(#window.page_items==2 and #window.page_items[1]==2 and window.page_items[2][1]==3,
    'Page boundaries must account for added row padding')
window:setupItemHeights()
assert(window.item_table[1].height==36,'Repeated layout must not accumulate padding')
local actions
UI.show=function(_,widget) actions=widget end
window.item_table[1].callback()
assert(not opened and actions.buttons[1][1].text=='Work details')
actions.buttons[2][1].callback();assert(opened.id=='1' and opened.read)
opened.last_accessed='2026-11-01'
local function option(row,choice)
    window.library_model.buttons[1][1].callback()
    actions.buttons[row][1].callback()
    if choice then actions.buttons[choice][1].callback() end
end
assert(not window.library_model.filters and not window.library_model.scope,'Controls should stay inside View options')
option(2,2)
assert(window.library_model.visible==2 and #window.item_table==2)
assert(window.item_table[1].work.id=='2','New chapters missing from saved chapter flags must stay unread')
local reviewed
package.loaded['ao3lib.ui.update_review']={showWorks=function(_,works,label) reviewed={works=works,label=label} end}
window.library_model.review()
assert(#reviewed.works==2 and reviewed.label=='Entire library · Unread (including started)')
option(1)
assert(actions.title=='Show downloaded works')
actions.buttons[2][1].callback()
assert(actions.title=='Choose author')
for _,row in ipairs(actions.item_table) do if row.text=='Writer (2)' then row.callback();break end end
assert(window.library_model.scope_label=='Author: Writer' and window.library_model.total==2 and #window.item_table==1)
window.library_model.review()
assert(#reviewed.works==1 and reviewed.works[1].id=='2')
option(2,1)
-- Fandom grouping also handles crossovers and scopes the list correctly.
option(1);actions.buttons[3][1].callback()
assert(actions.title=='Choose fandom')
local fandom_found=false
for _,row in ipairs(actions.item_table) do
    if row.text=='Fandom (2)' then fandom_found=true;row.callback();break end
end
assert(fandom_found and window.library_model.total==2 and #window.item_table==2)
option(1);actions.buttons[2][1].callback()
for _,row in ipairs(actions.item_table) do if row.text=='Writer (2)' then row.callback();break end end
option(5)
assert(actions.title=='Sort downloaded works')
actions.buttons[3][1].callback()
assert(window.item_table[1].work.id=='2' and window.library_model.sort=='recent')
option(2,5);assert(#window.item_table==1 and window.item_table[1].work.id=='1')
-- Independent filters intersect, and reset restores the whole library.
option(7)
option(2,3);assert(#window.item_table==1 and window.item_table[1].work.id=='3')
option(2,4);assert(#window.item_table==1 and window.item_table[1].work.id=='2')
option(2,1)
option(3,3);assert(#window.item_table==1 and window.item_table[1].work.id=='3')
option(3,2);assert(#window.item_table==2)
option(4,3);assert(#window.item_table==2)
option(4,2);assert(#window.item_table==0)
option(7)
option(1);actions.buttons[2][1].callback()
for _,row in ipairs(actions.item_table) do if row.text=='Writer (2)' then row.callback();break end end
option(2,5)
-- Rendered view uses exactly the filtered offline works and local actions.
local WorkView=require('ao3lib.ui.work_view')
local nativeShow=WorkView.show
local rendered_context,rendered_state
WorkView.show=function(_,context)
    rendered_context=context
    context.present=function() end
    rendered_state=WorkView.new(context)
    rendered_state.window={}
    rendered_state:render()
    return rendered_state
end
window.item_table[1].callback();actions.buttons[1][1].callback()
assert(rendered_state and rendered_state.works[rendered_state.index].id=='1','List details should open the selected rendered work')
rendered_setting=true
window._ao3_navigation.options.resume()
assert(rendered_context and #rendered_state.works==1 and rendered_state.works[1].id=='1')
assert(not rendered_context.fetch,'Rendered local works must never fetch AO3 pages')
assert(rendered_context.summary_html,'EPUB summary markup must use the local summary normalizer')
local local_rows=rendered_context.rows(rendered_state.works[1])
assert(local_rows[1].callback and local_rows[2][2]=='Writer','Rendered title must open work actions')
local author_opened
plugin.onShowAuthor=function(_,author) author_opened=author end
local_rows[2].callback();assert(author_opened=='Writer','Rendered author must open its profile')
local series_work={id='series-work',title='Series work',author='Pseud (account), Coauthor',series={{id='42',title='Series title',position=2}}}
local series_rows=rendered_context.rows(series_work)
series_rows[2].callback()
assert(actions.title:find('authors',1,true))
actions.buttons[1][1].callback();assert(author_opened=='Pseud (account)')
local Network=require('ao3lib.ao3.network')
local run=Network.run;Network.run=function(fn,...) return fn(...) end
local series_opened
plugin.getWorksFromSeries=function(_,id) assert(id=='42');return true,{{id='member',title='Member'}} end
plugin.onShowFanficBrowser=function(_,works,_,title) series_opened={works=works,title=title} end
series_rows[3].callback()
actions.buttons[1][1].callback()
assert(series_opened.title=='Series title' and series_opened.works[1].id=='member')
Network.run=run
local html,links=WorkView.html(series_work,series_rows,{summary_html=true})
assert(#links==3 and html:find('<h1><a',1,true),'Title actions and author/series navigation must all remain available')
assert(not rendered_context.work_controls,'Read and More must not be permanent controls')
local_rows[1].callback()
local more_labels={}
for _,row in ipairs(actions.buttons) do for _,button in ipairs(row) do more_labels[button.text]=true end end
assert(not more_labels['Work details'] and more_labels['Open for reading'])
for _,row in ipairs(actions.buttons) do for _,button in ipairs(row) do
    if button.text=='Open for reading' then button.callback() end
end end
assert(opened.id=='1')
assert(more_labels['Select chapter'] and more_labels['Check for updates'] and more_labels['Delete local copy'])
rendered_context.list();assert(actions.title=='Downloaded works · View options')
rendered_setting=false
window._ao3_navigation.options.resume()
assert(not rendered_context.work_controls)
WorkView.show=nativeShow
-- Delete and ignore late cache validation that still reports the removed file.
local WorkActions=require('ao3lib.ui.work_actions')
local original=WorkActions.show
local options
WorkActions.show=function(_,_,value) options=value end
window.item_table[1].callback();options.deleted();options.refresh()
pending.done({['1']=a,['2']=b,['3']=c})
assert(window.library_model.total==1 and #window.item_table==0)
WorkActions.show=original
window:onCloseWidget();assert(pending.cancelled)
local model=window.library_model
pending.done({['1']=a})
assert(window.library_model==model,'Closed screens must ignore late results')
local reopened=Menu:onViewDownloadedFanfics()
assert(reopened.library_model.total==1 and reopened.library_model.filter=='read','Reopen should restore the saved view and cached library')
visible=false
assert(not jobs[#jobs].valid())
reopened:onCloseWidget()
assert(reopened.is_borderless and not reopened.is_popout and reopened.linesize==0 and reopened.with_bottom_line)
-- Imported works without recognized metadata remain visible offline.
visible=true;view_settings=nil
snapshot={['222']={id='222',path='/books/localized.epub',title='Localized work'}}
local unknown_window=Menu:onViewDownloadedFanfics()
assert(#unknown_window.item_table==1 and unknown_window.item_table[1].work.id=='222')
assert(unknown_window.item_table[1].text:find('Anonymous',1,true))
unknown_window:onCloseWidget()
print('PASS: fixed downloaded-library controls; cached offline loading; reading filters; coauthor scope; sort; visible-only update review; deletion and cancellation')
