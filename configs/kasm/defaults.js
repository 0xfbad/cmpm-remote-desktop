(function () {
  var p = new URLSearchParams(location.search);
  var changed = false;
  function set(k, v) {
    if (!p.has(k)) {
      p.set(k, v);
      changed = true;
    }
  }
  set("clipboard_seamless", "true");
  set("autoconnect", "1");
  set("resize", "remote");
  if (changed) {
    history.replaceState(null, "", "?" + p.toString());
  }
})();
