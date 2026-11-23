-- A persistent progress toast is not the lifetime anchor of an AO3 request.
package.path='./?.lua;'..package.path
package.loaded['ffi/util']={}
package.loaded.logger={warn=function(_,err) error(err) end}
local page={}
local toast={toast=true}
local stack={page,toast}
package.loaded['ui/uimanager']={getTopmostVisibleWidget=function() return stack[#stack] end,
    getNthTopWidget=function(_,n) return stack[#stack-n+1] end,
    isWidgetShown=function(_,widget) for _,w in ipairs(stack) do if w==widget then return true end end;return false end}
local Background=require('ao3lib.ao3.background')
local complete,options
Background.run=function(_,done,opts) complete=done;options=opts;return {} end
local result
local co=coroutine.create(function() result=Background.await(function() end,{silent=true}) end)
assert(coroutine.resume(co) and coroutine.status(co)=='suspended')
stack={page}
assert(options.valid(),'Removing an overlay must not cancel the request')
complete('ok')
assert(coroutine.status(co)=='dead' and result=='ok')
print('PASS: background requests ignore progress toasts when choosing their lifetime anchor')
