-- Plugin-owned SVGs: resolve by name without copying files into KOReader.
local M={name="ao3"}
local source=debug.getinfo(1,"S").source
local directory=source:sub(1,1)=="@" and source:sub(2):match("^(.*[/\\])") or "./"
M.file=(directory or "./").."assets/ao3.svg"

function M.install()
    local ok,Icon=pcall(require,"ui/widget/iconwidget")
    if not ok or type(Icon.init)~="function" then return false end
    if not Icon._ao3_icon_installed then
        local init=Icon.init
        Icon.init=function(widget,...)
            if widget.icon==M.name and not widget.file and not widget.image then widget.file=M.file end
            return init(widget,...)
        end
        Icon._ao3_icon_installed=true
    end
    return true
end

function M.installBookshelf()
    if not M.install() then return false end
    local ok,Icons=pcall(require,"lib/bookshelf_icons_library")
    if not ok or type(Icons._scanUserIcons)~="function" then return false end
    if not Icons._ao3_icon_installed then
        local scan=Icons._scanUserIcons
        Icons._scanUserIcons=function(...)
            local items=scan(...)
            for _,item in ipairs(items) do if item.icon==M.name then return items end end
            -- Do not mutate Bookshelf's cached list of user files.
            local out={};for i,item in ipairs(items) do out[i]=item end
            out[#out+1]={icon=M.name,label="AO3",insert_value="[icon=ao3]",is_image=true,search_lc="ao3"}
            return out
        end
        Icons._ao3_icon_installed=true
    end
    return true
end
return M
