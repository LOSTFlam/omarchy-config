import QtQuick
import QtTest
import "../../ui" as Ui

TestCase {
  id: testCase
  name: "OutfitConfirmation"
  when: windowShown
  visible: true
  width: 760
  height: 540
  Component { id: component; Ui.ConfirmationDialog { width:760; height:540 } }
  Component { id: spyComponent; SignalSpy {} }
  function test_cancel_default_keyboard_and_pointer_remain_explicit() {
    var dialog = createTemporaryObject(component,testCase,{opened:true,message:"Uninstall the fictional plugin?",confirmText:"Uninstall"})
    verify(dialog !== null)
    var canceled = createTemporaryObject(spyComponent,testCase,{target:dialog,signalName:"canceled"})
    var confirmed = createTemporaryObject(spyComponent,testCase,{target:dialog,signalName:"confirmed"})
    var cancelButton = findChild(dialog,"confirmationCancel")
    var acceptButton = findChild(dialog,"confirmationAccept")
    compare(cancelButton.radius,dialog.cornerRadius)
    compare(acceptButton.radius,cancelButton.radius)
    compare(dialog.selectedIndex,0)
    verify(dialog.handleKey({key:Qt.Key_Return}))
    compare(canceled.count,1)
    compare(confirmed.count,0)
    verify(dialog.handleKey({key:Qt.Key_Right}))
    verify(dialog.handleKey({key:Qt.Key_Return}))
    compare(confirmed.count,1)
    verify(dialog.handleKey({key:Qt.Key_Escape}))
    compare(canceled.count,2)
    wait(0)
    mouseClick(cancelButton,cancelButton.width/2,cancelButton.height/2)
    compare(canceled.count,3)
    compare(confirmed.count,1)
    dialog.cornerRadius = 12
    compare(cancelButton.radius,12)
    compare(acceptButton.radius,12)
    dialog.opened = false
    verify(!dialog.handleKey({key:Qt.Key_Return}))
    compare(confirmed.count,1)
  }
}
