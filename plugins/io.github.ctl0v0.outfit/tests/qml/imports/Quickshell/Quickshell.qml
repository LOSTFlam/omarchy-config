pragma Singleton
import QtQuick
QtObject {
  function env(name) { return name === "HOME" ? "/fictional/home" : "" }
  property string clipboardText: ""
}
