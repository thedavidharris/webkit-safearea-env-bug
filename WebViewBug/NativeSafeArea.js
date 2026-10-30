// Called synchronously by an atDocumentStart WKUserScript. The root already exists.
function installNativeSafeArea(initialInsets, initialRevision) {
    const documentID = globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random()}`;
    let appliedRevision = -1;
    const edges = ["top", "right", "bottom", "left"];
    const bridge = {
        documentID,
        apply(insets, revision, expectedDocumentID) {
            if (expectedDocumentID !== documentID || revision < appliedRevision) return false;
            if (!Number.isFinite(revision) || !edges.every(edge =>
                Number.isFinite(insets[edge]) && insets[edge] >= 0)) return false;
            let changed = false;
            for (const edge of edges) {
                const name = `--native-safe-area-inset-${edge}`;
                const value = `${insets[edge]}px`;
                if (document.documentElement.style.getPropertyValue(name) !== value) {
                    document.documentElement.style.setProperty(name, value);
                    changed = true;
                }
            }
            appliedRevision = revision;
            if (changed) window.dispatchEvent(new Event("native-safe-area-change"));
            return true;
        }
    };
    window.__nativeSafeAreaBridge = bridge;
    bridge.apply(initialInsets, initialRevision, documentID);
    // Reconciliation is asynchronous; the initial values above do not wait for a reply.
    window.webkit?.messageHandlers?.probe?.postMessage({event: "bridge-ready", documentID});
}
