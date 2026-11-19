dofile("tests/test_network.lua")
local UI=require("ui/uimanager")
local shown={}
UI.show=function(_,widget) shown[#shown+1]=widget end
local Multi={}
function Multi:new(args)
    args.getFields=function(self) return self.values or {"",""} end
    args.onShowKeyboard=function() end
    return args
end
package.loaded["ui/widget/multiinputdialog"]=Multi
package.loaded["ao3lib.ui.search_filters_menu"]=nil
local Filter=require("ao3lib.ui.search_filters_menu")
Filter.menuWidget={updateItems=function() end}
Filter.filter={}
Filter:selectWordCount()
local dialog=shown[#shown]
dialog.values={"10000","25000"};dialog.buttons[1][3].callback()
assert(Filter.filter.word_count=="10000-25000")
Filter:selectWordCount();dialog=shown[#shown]
dialog.values={"50000",""};dialog.buttons[1][3].callback()
assert(Filter.filter.word_count==">49999")
Filter:selectWordCount();dialog=shown[#shown]
dialog.buttons[1][2].callback()
assert(Filter.filter.word_count==nil)
print("PASS: word-count dialog applies inclusive ranges and clears the filter")
