-- Completion tracking must stay silent, including single-chapter works.
dofile('tests/test_reader_tracking.lua')
local Reader=require('ao3lib.ui.reader')
local UI=package.loaded['ui/uimanager']
local History=package.loaded["ao3lib.library.history"]
UI.show=function() error('Completion must not display a widget') end
UI.scheduleIn=function() error('Completion must not schedule a notification') end
local chapters,works=0,0
History.markChapterAsRead=function(id,index)
    assert(id=='silent' and index==1)
    chapters=chapters+1
    return true
end
History.markWorkAsRead=function(id)
    assert(id=='silent')
    works=works+1
    return true
end
Reader.current_fanfic={id='silent',title='Work',chapter_data={{name='Last'}}}
Reader:onFinishChapter(1)
Reader:onFinishChapter(1)
assert(chapters==1 and Reader.current_fanfic.chapter_data[1].read)
Reader:onFinishSingleChapterWork()
Reader:onFinishSingleChapterWork()
assert(works==1 and Reader.current_fanfic.read)
print('PASS: chapter/work completion stays silent and still records progress once')
