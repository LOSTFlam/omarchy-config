pragma Singleton
import QtQuick
QtObject {
  function controlSpec(state, foreground, accent) { return {state:state} }
  function none() { return {} }
}
