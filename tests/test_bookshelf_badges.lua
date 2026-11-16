-- Real Bookshelf registry and KOReader layout widgets; only device/decoder
-- boundaries are stubbed. Run from the AO3 plugin root with luajit.
package.path = './?.lua;../bookshelf.koplugin/?.lua;../koreader/frontend/?.lua;' .. package.path
package.loaded['ui/bidi'] = {mirroredUILayout=function() return true end}
package.loaded.util = {arrayReverse=function() error('AO3 positions must not mirror') end}
package.loaded.logger = {warn=function() end}
package.loaded.dbg = {guard=function(fn) return fn end}
local eink = false
package.loaded.fanfic_config = {readSetting=function(_, key, default)
    if key == "ao3_eink_symbols" then return eink end
    return default
end}
local dpi = 1
package.loaded.device = {screen={scaleBySize=function(_, n) return n*dpi end}}
local epub = {id='123', rating='Explicit', categories={'F/M'},
    warnings={'Creator Chose Not To Use Archive Warnings'}, chapters='2/?'}
package.loaded.fanfic_epub = {read=function(fp)
    if fp == '/broken.epub' then error('corrupt EPUB') end
    if fp == '/ao3.epub' then return epub end
end}
package.loaded.downloaded_fanfics = setmetatable({}, {__index=function()
    error('Cover rendering must not read history')
end})
local Widget = require('ui/widget/widget')
local painted, fail_decode = {}, false
local Image = Widget:extend{}
function Image:getSize()
    assert(not self.freed, 'freed widget reused')
    if fail_decode then error('decoder failure') end
    local f = assert(io.open(self.file, 'rb'))
    assert(f:read(8) == '\137PNG\r\n\26\n'); f:close()
    return {w=self.width, h=self.height}
end
function Image:paintTo(_, x, y)
    self:getSize()
    painted[#painted+1] = {self.file:match('([^/]+)%.png$'), x, y}
end
function Image:free() self.freed = true end
package.loaded['ui/widget/imagewidget'] = Image
local Badges = require('fanfic_bookshelf_badges')
local P = require('lib/bookshelf_placeholders')
local Spine = {_renderFallback=function(self)
    local custom = P.widgetFor({filepath='/ao3.epub'}, 100, 160, self.ctx)
    if self.raise then error('fallback failure') end
    return custom or {native_placeholder=true}
end}
package.loaded['lib/bookshelf_spine_widget'] = Spine
local Box = {_initSlipcase=function(self)
    -- Match the slipcase's cover sticker: flat, with no face-out flag.
    self.art_cover = Spine._renderFallback({ctx={flat=true}})
    if self.raise then error('slipcase failure') end
    return self.art_cover
end}
package.loaded['lib/bookshelf_series_box_widget'] = Box
assert(Badges.install()); assert(Badges.install())
local hooked = Spine._renderFallback
local hooked_box = Box._initSlipcase
assert(Badges.install() and Spine._renderFallback==hooked, 'do not wrap the renderer twice')
assert(Box._initSlipcase==hooked_box, 'do not wrap series slipcases twice')
assert(Spine._renderFallback({spine_face_out=true}).native_placeholder,
    'spines must retain the native book placeholder')
assert(Box._initSlipcase({}).native_placeholder,
    'series cover stickers in spines view must retain the native placeholder')
assert(not pcall(Box._initSlipcase,{raise=true}))
for _, ctx in ipairs({{}, {bare=true,flat=true}, {panel=true}}) do
    local custom = Spine._renderFallback({ctx=ctx})
    assert(custom.ao3_badges, 'grid, list and top panel must retain AO3 badges')
    custom:free()
end
assert(not pcall(Spine._renderFallback, {spine_face_out=true,raise=true}))
local after_error = Spine._renderFallback({ctx={panel=true}})
assert(after_error.ao3_badges, 'failed spines rendering must not suppress later badges')
after_error:free()
local count=0; for _ in pairs(package.loaded[P.KEY]) do count=count+1 end
assert(count==1, 'installation must replace the existing provider')
local function symbols(data, expected)
    local got=Badges.symbols(data)
    for i=1,4 do assert(got[i] == expected[i], 'wrong symbol in position '..i) end
end
symbols({}, {'rating-notrated', 'category-none', false, false})
for label, icon in pairs({['General Audiences']='general-audience',
    ['Teen And Up Audiences']='teen', Mature='mature', Explicit='explicit', ['Not Rated']='notrated'}) do
    assert(Badges.symbols({ao3_ratings={label}})[1] == 'rating-'..icon)
end
for label, icon in pairs({['F/M']='het', ['M/F']='het', ['F/F']='femslash', ['M/M']='slash',
    Gen='gen', Multi='multi', Other='other'}) do
    assert(Badges.symbols({ao3_categories={label}})[2] == 'category-'..icon)
end
assert(Badges.symbols({ao3_categories={'F/M','M/F'}})[2] == 'category-het')
assert(Badges.symbols({ao3_categories={'F/M','F/F'}})[2] == 'category-multi')
for label, icon in pairs({['No Archive Warnings Apply']='no', ['External Work']='external-work',
    ['Creator Chose Not To Use Archive Warnings']='choosenotto', ['Major Character Death']='yes'}) do
    assert(Badges.symbols({ao3_warnings={label}})[3] == 'warning-'..icon)
end
assert(Badges.symbols({ao3_warnings={'Major Character Death',
    'Creator Chose Not To Use Archive Warnings', 'No Archive Warnings Apply'}})[3] == 'warning-yes')
for status, icon in pairs({complete='yes', in_progress='no', unknown=false}) do
    assert(Badges.symbols({ao3_completion={status}})[4] == (icon and 'complete-'..icon or false))
end
for _, fp in ipairs({'/ordinary.epub', '/broken.epub', '/ao3.pdf'}) do
    assert(P.widgetFor({filepath=fp}, 100, 150) == nil)
end
local grid, opts = P.widgetFor({filepath='/ao3.epub'}, 100, 160, {panel=true})
assert(grid and opts.frame==false)
assert(grid:getSize().w==82 and grid:getSize().h==98, 'panel must include only a small top inset')
grid:paintTo({}, 10, 20)
local names={'rating-explicit','category-het','warning-choosenotto','complete-no'}
for i=1,4 do
    assert(painted[i][1]==names[i])
    assert(painted[i][2]==10+((i-1)%2)*42 and painted[i][3]==36+math.floor((i-1)/2)*42)
end
grid:free()
grid = assert(P.widgetFor({filepath='/ao3.epub'}, 100, 160, {panel=true}))
grid:paintTo({}, 0, 0); grid:free()
grid = assert(P.widgetFor({filepath='/ao3.epub'}, 100, 160, {bare=true}))
assert(grid:getSize().w==58 and grid:getSize().h==58, 'list badges should use the larger square')
painted = {}; grid:paintTo({}, 10, 20)
assert(painted[1][2]==10 and painted[1][3]==20, 'list badges must not move down')
grid:free()
for _, scale in ipairs({1,2,3}) do
    dpi=scale
    for _, ctx in ipairs({{}, {panel=true}, {bare=true}, {flat=true}}) do
        for _, size in ipairs({{16,16},{21,35},{51,80},{200,300}}) do
            grid = P.widgetFor({filepath='/ao3.epub'}, size[1], size[2], ctx)
            if grid then
                assert(grid:getSize().w<=size[1] and grid:getSize().h<=size[2])
                grid:free()
            else
                local top=ctx.panel and math.min(16*scale, math.max(0,size[2]-16)) or 0
                assert(math.floor((math.min(size[1],size[2]-top)-2*scale)/2)<7)
            end
        end
    end
end
assert(P.widgetFor({filepath='/ao3.epub'}, 5, 5) == nil)
eink = true
grid = assert(P.widgetFor({filepath='/ao3.epub'}, 100, 160))
assert(grid[1][1].file:find('assets/ao3-icons-eink/rating-explicit.png', 1, true))
assert(grid[1][3].file:find('assets/ao3-icons-eink/category-het.png', 1, true))
assert(grid[3][1].file:find('assets/ao3-icons-eink/warning-choosenotto.png', 1, true))
assert(grid[3][3].file:find('assets/ao3-icons-eink/complete-no.png', 1, true))
grid:free()
eink = false
epub.chapters, epub.warnings = '?/?', nil
grid = assert(P.widgetFor({filepath='/ao3.epub'}, 100, 160))
assert(grid[3][1].file == nil and grid[3][3].file == nil)
grid:free()
fail_decode=true
assert(P.widgetFor({filepath='/ao3.epub'}, 100, 160) == nil, 'decoding must fail before painting')
print('PASS: badge mappings, warning priority, unknown metadata, EPUB-only identity, RTL positions, compact layout, DPI bounds, disposal, decode failure, native registry/idempotence')
