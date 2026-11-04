/*
 * chargelimit's Kindle app. ES5 only: Mesquite is WebKit 533.
 *
 * The page asks the bridge (bridge.sh behind BusyBox tcpsvd on 127.0.0.1)
 * for the state first. Until chargelimit is installed, only Install works;
 * once it is, Install shows "Installed" (greyed out) unless this build or
 * the boot files are missing, and the other buttons run actions of
 * actions.sh. After each one it shows the action's text and refreshes the
 * status and the setting buttons' labels. BRIDGE and TOKEN come from
 * bridge.js, written by open-app.sh.
 */
(function () {
    var busy = false;
    var uninstallArmed = null;

    function el(id) { return document.getElementById(id); }

    function setText(node, text) {
        node.innerHTML = "";
        node.appendChild(document.createTextNode(text));
    }

    // GET BRIDGE/<action>; callback(text, error). Diagnostics can take a
    // few seconds, and installing longer (stopping the old daemon, or a
    // report on an unsupported Kindle), hence the long timeouts.
    function call(action, callback) {
        var xhr = new XMLHttpRequest();
        var done = false;
        var seconds = action === "install" ? 60 : 30;
        var timer = setTimeout(function () {
            if (!done) { done = true; xhr.abort(); callback(null, "no answer after " + seconds + " s"); }
        }, seconds * 1000);
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== 4 || done) return;
            done = true;
            clearTimeout(timer);
            if (xhr.status === 200) {
                callback(xhr.responseText.replace(/\s+$/, ""), null);
            } else if (xhr.status === 0) {
                callback(null, "not running");
            } else {
                callback(null, "HTTP " + xhr.status + ": " + xhr.responseText);
            }
        };
        try {
            xhr.open("GET", BRIDGE + action + "?token=" + TOKEN + "&_=" + new Date().getTime(), true);
            xhr.send(null);
        } catch (e) {
            done = true;
            clearTimeout(timer);
            callback(null, String(e));
        }
    }

    function problem(err) {
        return "Couldn't reach chargelimit (" + err + ").\n" +
            "Close this with × and open Charge limit from the library again.";
    }

    // "key=value" lines into an object.
    function parse(text) {
        var result = {};
        var lines = text.split("\n");
        for (var i = 0; i < lines.length; i++) {
            var eq = lines[i].indexOf("=");
            if (eq > 0) result[lines[i].substring(0, eq)] = lines[i].substring(eq + 1);
        }
        return result;
    }

    // Everything but Install needs chargelimit installed.
    function enable(on) {
        var buttons = document.querySelectorAll("button[data-action]");
        for (var i = 0; i < buttons.length; i++) buttons[i].disabled = !on;
        el("uninstall").disabled = !on;
    }

    // The install state, then the status text and the setting buttons'
    // labels.
    function refresh() {
        call("state", function (text, err) {
            var install = el("install");
            if (err) {
                setText(el("status"), problem(err));
                return;
            }
            var state = parse(text);
            var installed = state.installed === "yes";
            var current = state.current === "yes";
            setText(install, current ? "Installed" : "Install");
            install.disabled = current;
            enable(installed);
            setText(el("version"), "chargelimit " + state.version);
            if (!installed) {
                setText(el("status"), "chargelimit isn't installed yet.\n" +
                    "Install adds the charge limiter, which then starts by itself with the Kindle.");
                return;
            }
            // Installed, but a newer build is in chargelimit/install, or a
            // firmware update removed the start at boot.
            var note = current ? "" : "Tap Install to update chargelimit or repair its start at boot.\n\n";
            call("status", function (text, err) {
                setText(el("status"), note + (err ? problem(err) : text));
            });
            call("labels", function (text, err) {
                if (err) return;
                var labels = parse(text);
                for (var key in labels) {
                    var button = document.querySelector('button[data-action="' + key + '"]');
                    if (button) setText(button, labels[key]);
                }
            });
        });
    }

    function run(action, waiting) {
        if (busy) return;
        busy = true;
        setText(el("message"), waiting || "...");
        call(action, function (text, err) {
            busy = false;
            setText(el("message"), err ? problem(err) : text);
            refresh();
        });
    }

    var buttons = document.querySelectorAll("button[data-action]");
    for (var i = 0; i < buttons.length; i++) {
        buttons[i].addEventListener("click", (function (action) {
            return function () { run(action); };
        }(buttons[i].getAttribute("data-action"))), false);
    }

    el("install").addEventListener("click", function () {
        run("install", "Installing...");
    }, false);

    // Uninstalling takes a second tap within 5 s.
    el("uninstall").addEventListener("click", function () {
        if (uninstallArmed) {
            clearTimeout(uninstallArmed);
            uninstallArmed = null;
            setText(el("uninstall"), "Uninstall chargelimit");
            run("uninstall");
            return;
        }
        setText(el("uninstall"), "Tap again to uninstall");
        uninstallArmed = setTimeout(function () {
            uninstallArmed = null;
            setText(el("uninstall"), "Uninstall chargelimit");
        }, 5000);
    }, false);

    // open-app.sh sends this when the app was already open in the background.
    try {
        window.kindle.messaging.receiveMessage("refresh", function () {
            setText(el("message"), "");
            refresh();
        });
    } catch (e) { /* outside a Kindle */ }

    refresh();
}());
