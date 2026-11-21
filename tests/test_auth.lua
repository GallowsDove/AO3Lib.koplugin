package.path='./?.lua;'..package.path
local shown,tasks={},{}
local UI={show=function(_,w) shown[#shown+1]=w end,close=function() end,
    nextTick=function(_,f) tasks[#tasks+1]=f end}
package.loaded['ui/uimanager']=UI
local Class={}
function Class:new(t) return setmetatable(t,{__index=self}) end
function Class:addWidget(w) self.check=w end
function Class:onShowKeyboard() end
function Class:getFields() return {'Writer','secret'} end
for _,n in ipairs{'multiinputdialog','checkbutton','infomessage'} do package.loaded['ui/widget/'..n]=Class end
package.loaded['ao3lib.ao3.network']={wrap=function(f) return f end}
package.loaded.logger={warn=function() error('unexpected continuation failure') end}
local A=require('ao3lib.ui.auth')
local status={success=false,error='Maintenance'}
local remembered,login_ok
local client={GetSessionStatus=function() return status end,
    startLoggedInSession=function(_,user,password,remember)
        assert(user=='Writer' and password=='secret');remembered=remember
        return {success=login_ok,error='Try again later'}
    end}
assert(not A.recover(client) and #shown==0)
status={success=true,logged_in=true}
assert(A.recover(client) and #shown==0)
status={success=true,logged_in=false}
local outcome
local function start()
    outcome=nil
    local co=coroutine.create(function() outcome=A.recover(client) end)
    assert(coroutine.resume(co));return co,shown[#shown]
end
local co,dialog=start()
assert(coroutine.status(co)=='suspended' and dialog.check.checked)
-- An outage during login retains the dialog and the suspended operation.
login_ok=false;dialog.buttons[1][2].callback()
assert(outcome==nil and #tasks==0)
login_ok=true;dialog.check.checked=false;dialog.buttons[1][2].callback()
assert(remembered==false and outcome==nil)
table.remove(tasks,1)();assert(outcome==true and coroutine.status(co)=='dead')
co,dialog=start();dialog.buttons[1][1].callback();table.remove(tasks,1)()
assert(outcome==false and coroutine.status(co)=='dead')
print('PASS: outages never prompt; persistent-session restoration; login opt-out; failed login retention; cancellation and continuation')
