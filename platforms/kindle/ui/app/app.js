/*
 * The Kindle app. ES5 only: Mesquite is WebKit 533. BRIDGE and TOKEN come
 * from bridge.js, written by open-app.sh.
 */
(function () {
    var busy = false;
    var uninstallArmed = null;
    // The last action's text, shown above the status.
    var message = "";
    // The status last shown under it.
    var shown = "";
    var polling = false;
    var refreshId = 0;

    function el(id) { return document.getElementById(id); }

    function setText(node, text) {
        node.innerHTML = "";
        node.appendChild(document.createTextNode(text));
    }

    function showInfo(text) {
        shown = text;
        setText(el("info"), message ? message + "\n\n" + text : text);
    }

    // GET BRIDGE/<action>; callback(text, error).
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
        return "Couldn't reach Charge Limit (" + err + ").\n" +
            "Close this with × and open Charge Limit from the library again.";
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

    // Only Install and Charge diagnostics work before installing.
    function enable(installed) {
        var buttons = document.querySelectorAll("button[data-action]:not([aria-pressed])");
        for (var i = 0; i < buttons.length; i++) {
            buttons[i].disabled = !installed && buttons[i].getAttribute("data-action") !== "diagnose";
        }
        el("uninstall").disabled = !installed;
    }

    function showChoices(id, action, available) {
        var buttons = el(id).querySelectorAll("button");
        for (var i = 0; i < buttons.length; i++) {
            buttons[i].disabled = !available;
            buttons[i].setAttribute("aria-pressed", String(available && buttons[i].getAttribute("data-action") === action));
        }
    }

    function showSettings(labels) {
        var available = !!labels.enabled_value;
        // Keep the old controls until Install updates an older runtime.
        var legacy = !available && labels.limit;
        el("direct-settings").style.display = legacy ? "none" : "";
        el("legacy-settings").style.display = legacy ? "" : "none";
        showChoices("limit-options", "limit-" + (labels.enabled_value === "0" ? "off" : labels.limit_value), available);
        showChoices("restart-options", labels.start_value === "1" ? "start-on" : "start-off", available);
    }

    // While the guided report runs (Charge diagnostics on an unsupported
    // Kindle), show its step every 5 s, then its result.
    function pollProgress() {
        if (polling) return;
        polling = true;
        call("progress", function (text, err) {
            polling = false;
            if (err || busy) return;
            var first = text.split("\n")[0];
            if (first === "idle") return;
            message = text.substring(first.length + 1);
            showInfo(shown);
            if (first === "running") setTimeout(pollProgress, 5000);
        });
    }

    function refresh() {
        var id = ++refreshId;
        call("state", function (text, err) {
            if (id !== refreshId) return;
            var install = el("install");
            if (err) {
                showInfo(problem(err));
                return;
            }
            var state = parse(text);
            var installed = state.installed === "yes";
            var current = state.current === "yes";
            var supported = state.supported === "yes";
            setText(install, current ? "Installed" : "Install");
            install.disabled = current || !supported;
            enable(installed);
            setText(el("version"), "Charge Limit " + state.version);
            if (!installed) {
                showSettings({});
                showInfo(supported ?
                    "This Kindle is supported, and Charge Limit isn't installed yet.\n" +
                    "Install adds the charge limiter, which then starts by itself with the Kindle." :
                    "This Kindle isn't supported yet, so Charge Limit can't be installed.\n" +
                    "Charge diagnostics guides you through a short test and saves a report, chargelimit/diagnostics.log, to send with a request to support it.");
                if (!supported) pollProgress();
                return;
            }
            var note = current ? "" : "Tap Install to update Charge Limit or repair its start at boot.\n\n";
            call("labels", function (text, err) {
                if (id !== refreshId) return;
                if (err) {
                    showInfo(note + problem(err));
                    return;
                }
                var split = text.indexOf("\n\n");
                var labels = parse(split < 0 ? text : text.substring(0, split));
                showSettings(labels);
                for (var key in labels) {
                    var button = document.querySelector('button[data-action="' + key + '"]');
                    if (button) setText(button, labels[key]);
                }
                if (split >= 0) {
                    showInfo(note + text.substring(split + 2));
                } else {
                    // Older installed versions return only labels here.
                    call("status", function (text, err) {
                        if (id === refreshId) showInfo(note + (err ? problem(err) : text));
                    });
                }
            });
        });
    }

    function run(action, waiting) {
        if (busy) return;
        busy = true;
        refreshId++;
        message = "";
        showInfo(waiting || "...");
        call(action, function (text, err) {
            busy = false;
            message = err ? problem(err) : text;
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
            setText(el("uninstall"), "Uninstall Charge Limit");
            run("uninstall");
            return;
        }
        setText(el("uninstall"), "Tap again to uninstall");
        uninstallArmed = setTimeout(function () {
            uninstallArmed = null;
            setText(el("uninstall"), "Uninstall Charge Limit");
        }, 5000);
    }, false);

    // "refresh": reopened (open-app.sh). "statusChanged": the daemon.
    try {
        window.kindle.messaging.receiveMessage("refresh", function () {
            if (busy) return;
            message = "";
            refresh();
        });
        window.kindle.messaging.receiveMessage("statusChanged", function () {
            if (!busy) refresh();
        });
    } catch (e) { /* outside a Kindle */ }

    refresh();
}());
