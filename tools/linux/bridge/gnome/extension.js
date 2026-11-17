import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

export default class WoliumBridge extends Extension {
  enable() {
    this._last = '';
    this._sent = 0;
    this._queued = 0;
    this._handles = [];
    const connect = (object, name) => this._handles.push([object, object.connect(name, () => this._queue())]);
    connect(global.display, 'notify::focus-window');
    connect(global.display, 'window-created');
    connect(global.window_manager, 'minimize');
    connect(global.window_manager, 'unminimize');
    connect(global.window_manager, 'destroy');
    this._timer = GLib.timeout_add_seconds(GLib.PRIORITY_LOW, 5, () => {
      this._send();
      return GLib.SOURCE_CONTINUE;
    });
    this._queue();
  }

  disable() {
    for (const [object, id] of this._handles) object.disconnect(id);
    this._handles = [];
    if (this._timer) GLib.source_remove(this._timer);
    if (this._queued) GLib.source_remove(this._queued);
    this._timer = 0;
    this._queued = 0;
  }

  _queue() {
    if (this._queued) return;
    this._queued = GLib.timeout_add(GLib.PRIORITY_LOW, 150, () => {
      this._queued = 0;
      this._send();
      return GLib.SOURCE_REMOVE;
    });
  }

  _collect() {
    const focus = global.display.focus_window;
    const windows = [];
    for (const actor of global.get_window_actors()) {
      const w = actor.meta_window;
      if (!w || w.get_window_type() !== Meta.WindowType.NORMAL) continue;
      windows.push({
        pid: w.get_pid(),
        class: w.get_wm_class() || '',
        instance: w.get_wm_class_instance() || '',
        active: w === focus,
        minimized: w.minimized,
      });
    }
    return JSON.stringify({windows});
  }

  _send() {
    const json = this._collect();
    const now = GLib.get_monotonic_time();
    if (json === this._last && now - this._sent < 10000000) return;
    this._last = json;
    this._sent = now;
    Gio.DBus.session.call(
      'org.wolium.Bridge',
      '/org/wolium/Bridge',
      'org.wolium.Bridge',
      'Report',
      new GLib.Variant('(s)', [json]),
      null,
      Gio.DBusCallFlags.NO_AUTO_START,
      1000,
      null,
      (connection, result) => {
        try {
          connection.call_finish(result);
        } catch (e) {
        }
      });
  }
}
