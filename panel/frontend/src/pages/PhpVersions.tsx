import { useState, useEffect, useRef, useCallback } from "react";
import { api } from "../api";

interface PhpVersion {
  id: string;
  server_id: string;
  version: string;
  status: "installing" | "active" | "removing" | "error";
  install_method: string;
  extensions: string[];
  error_message: string | null;
  created_at: string;
}

interface InstallStep {
  step: string;
  label: string;
  status: "pending" | "in_progress" | "done" | "error";
  message: string | null;
}

const ALL_VERSIONS = ["8.4", "8.3", "8.2", "8.1", "8.0", "7.4", "5.6"] as const;

const COMMON_EXTENSIONS = [
  "mbstring", "curl", "zip", "gd", "xml", "bcmath", "redis", "imagick",
];
const ALL_EXTENSIONS = [
  "mbstring", "curl", "zip", "gd", "xml", "bcmath", "intl", "soap", "opcache",
  "mysqli", "pgsql", "sqlite3", "pdo", "pdo-mysql", "pdo-pgsql",
  "redis", "imagick", "memcached", "xdebug", "mongodb", "ldap", "imap",
  "enchant", "tidy", "xmlrpc", "snmp", "readline",
];

function StatusBadge({ status }: { status: PhpVersion["status"] }) {
  const map: Record<string, string> = {
    active: "bg-rust-500/15 text-rust-400",
    installing: "bg-warn-500/15 text-warn-400",
    removing: "bg-warn-500/15 text-warn-400",
    error: "bg-danger-500/15 text-danger-400",
  };
  return (
    <span className={`inline-flex px-2 py-0.5 rounded-full text-xs font-medium ${map[status] ?? "bg-dark-700 text-dark-200"}`}>
      {status}
    </span>
  );
}

function InstallProgress({ progressUrl, onDone }: { progressUrl: string; onDone: () => void }) {
  const [steps, setSteps] = useState<InstallStep[]>([]);
  const doneRef = useRef(false);
  const onDoneRef = useRef(onDone);
  onDoneRef.current = onDone;

  useEffect(() => {
    const es = new EventSource(progressUrl);

    es.onmessage = (e) => {
      try {
        const step: InstallStep = JSON.parse(e.data);
        setSteps((prev) => {
          const idx = prev.findIndex((s) => s.step === step.step);
          if (idx >= 0) {
            const next = [...prev];
            next[idx] = step;
            return next;
          }
          return [...prev, step];
        });
        if (step.step === "complete" && !doneRef.current) {
          doneRef.current = true;
          es.close();
          setTimeout(() => onDoneRef.current(), 800);
        }
      } catch {
        // ignore malformed events
      }
    };

    es.onerror = () => es.close();
    return () => es.close();
  }, [progressUrl]);

  return (
    <div className="mt-4 space-y-2">
      {steps.map((s) => (
        <div key={s.step} className="flex items-center gap-2 text-sm">
          {s.status === "in_progress" && (
            <span className="w-3 h-3 border-2 border-dark-400 border-t-rust-500 rounded-full animate-spin" />
          )}
          {s.status === "done" && <span className="text-rust-400">✓</span>}
          {s.status === "error" && <span className="text-danger-400">✗</span>}
          {s.status === "pending" && <span className="w-3 h-3 rounded-full bg-dark-600" />}
          <span className={s.status === "error" ? "text-danger-400" : "text-dark-100"}>{s.label}</span>
          {s.message && <span className="text-xs text-dark-300 truncate max-w-xs">{s.message}</span>}
        </div>
      ))}
    </div>
  );
}

function ExtensionsPanel({
  version,
  installed,
  onClose,
  onRefresh,
}: {
  version: string;
  installed: string[];
  onClose: () => void;
  onRefresh: () => void;
}) {
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState("");

  const toggle = async (ext: string, isInstalled: boolean) => {
    setBusy(ext);
    setError("");
    try {
      if (isInstalled) {
        await api.delete(`/php/versions/${version}/extensions/${ext}`);
      } else {
        await api.post(`/php/versions/${version}/extensions`, { name: ext });
      }
      onRefresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Operation failed");
    } finally {
      setBusy(null);
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex">
      <div className="flex-1 bg-black/50" onClick={onClose} />
      <div className="w-96 bg-dark-900 border-l border-dark-600 flex flex-col">
        <div className="px-5 py-4 border-b border-dark-600 flex items-center justify-between">
          <h2 className="text-sm font-medium text-dark-50">
            PHP {version} Extensions
          </h2>
          <button type="button" onClick={onClose} className="text-dark-300 hover:text-dark-100">
            <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M6 18 18 6M6 6l12 12" />
            </svg>
          </button>
        </div>
        {error && (
          <div className="mx-5 mt-3 px-3 py-2 bg-danger-500/10 border border-danger-500/20 rounded text-sm text-danger-400">
            {error}
          </div>
        )}
        <div className="flex-1 overflow-y-auto p-5 space-y-2">
          {ALL_EXTENSIONS.map((ext) => {
            const isInstalled = installed.includes(ext);
            return (
              <div
                key={ext}
                className="flex items-center justify-between py-2 border-b border-dark-700 last:border-0"
              >
                <div>
                  <span className="text-sm text-dark-100 font-mono">{ext}</span>
                  {isInstalled && (
                    <span className="ml-2 text-xs text-rust-400">installed</span>
                  )}
                </div>
                <button
                  type="button"
                  onClick={() => toggle(ext, isInstalled)}
                  disabled={busy === ext}
                  className={`px-2.5 py-1 rounded text-xs font-medium transition-colors disabled:opacity-50 ${
                    isInstalled
                      ? "bg-danger-500/10 text-danger-400 hover:bg-danger-500/20"
                      : "bg-dark-700 text-dark-200 hover:bg-dark-600"
                  }`}
                >
                  {busy === ext ? "..." : isInstalled ? "Remove" : "Install"}
                </button>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}

function InstallModal({
  installedVersions,
  onClose,
  onRefresh,
}: {
  installedVersions: string[];
  onClose: () => void;
  onRefresh: () => void;
}) {
  const available = ALL_VERSIONS.filter((v) => !installedVersions.includes(v));
  const [version, setVersion] = useState<string>(available[0] ?? "8.3");
  const [method, setMethod] = useState<"native" | "docker">("native");
  const [selectedExts, setSelectedExts] = useState<string[]>(COMMON_EXTENSIONS);
  const [installing, setInstalling] = useState(false);
  const [progressUrl, setProgressUrl] = useState("");
  const [error, setError] = useState("");

  useEffect(() => {
    if (progressUrl) setInstalling(false);
  }, [progressUrl]);

  const toggleExt = (ext: string) => {
    setSelectedExts((prev) =>
      prev.includes(ext) ? prev.filter((e) => e !== ext) : [...prev, ext]
    );
  };

  const onDoneRefresh = useCallback(() => {
    onRefresh();
    onClose();
  }, [onRefresh, onClose]);

  const submit = async () => {
    setError("");
    setInstalling(true);
    try {
      const res = await api.post<{ progress_url: string }>("/php/versions", {
        version,
        method,
        extensions: selectedExts,
      });
      setProgressUrl(res.progress_url);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Install failed");
      setInstalling(false);
    }
  };

  if (available.length === 0) {
    return (
      <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60">
        <div className="bg-dark-800 border border-dark-600 rounded-xl p-6 w-full max-w-md">
          <p className="text-dark-200 text-sm">All supported PHP versions are already installed.</p>
          <button type="button" onClick={onClose} className="mt-4 px-4 py-2 bg-dark-700 text-dark-100 rounded-lg text-sm">
            Close
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60">
      <div className="bg-dark-800 border border-dark-600 rounded-xl p-6 w-full max-w-lg">
        <h2 className="text-sm font-medium text-dark-50 uppercase tracking-widest font-mono mb-5">
          Install PHP Version
        </h2>

        {progressUrl ? (
          <InstallProgress
            progressUrl={progressUrl}
            onDone={onDoneRefresh}
          />
        ) : (
          <div className="space-y-4">
            <div className="grid grid-cols-2 gap-4">
              <div>
                <label className="block text-xs font-medium text-dark-200 mb-1">Version</label>
                <select
                  value={version}
                  onChange={(e) => setVersion(e.target.value)}
                  className="w-full px-3 py-2 border border-dark-500 rounded-lg text-sm bg-dark-700 focus:ring-2 focus:ring-rust-500 outline-none"
                >
                  {available.map((v) => (
                    <option key={v} value={v}>
                      PHP {v}
                      {v === "8.3" ? " (recommended)" : ""}
                    </option>
                  ))}
                </select>
              </div>
              <div>
                <label className="block text-xs font-medium text-dark-200 mb-1">Install method</label>
                <select
                  value={method}
                  onChange={(e) => setMethod(e.target.value as "native" | "docker")}
                  className="w-full px-3 py-2 border border-dark-500 rounded-lg text-sm bg-dark-700 focus:ring-2 focus:ring-rust-500 outline-none"
                >
                  <option value="native">Native (Ondrej PPA)</option>
                  <option value="docker">Docker (FPM Alpine)</option>
                </select>
              </div>
            </div>

            {method === "native" && (
              <div>
                <label className="block text-xs font-medium text-dark-200 mb-2">Extensions</label>
                <div className="grid grid-cols-3 gap-1.5 max-h-40 overflow-y-auto pr-1">
                  {ALL_EXTENSIONS.map((ext) => (
                    <label key={ext} className="flex items-center gap-1.5 cursor-pointer">
                      <input
                        type="checkbox"
                        checked={selectedExts.includes(ext)}
                        onChange={() => toggleExt(ext)}
                        className="rounded border-dark-500"
                      />
                      <span className="text-xs text-dark-200 font-mono">{ext}</span>
                    </label>
                  ))}
                </div>
              </div>
            )}

            {error && (
              <p className="text-sm text-danger-400">{error}</p>
            )}

            <div className="flex items-center justify-end gap-3 pt-2">
              <button
                type="button"
                onClick={onClose}
                className="px-4 py-2 text-sm text-dark-200 hover:text-dark-100"
              >
                Cancel
              </button>
              <button
                type="button"
                onClick={submit}
                disabled={installing}
                className="px-4 py-2 bg-rust-500 hover:bg-rust-600 text-white rounded-lg text-sm font-medium disabled:opacity-50"
              >
                Install PHP {version}
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

export default function PhpVersions() {
  const [versions, setVersions] = useState<PhpVersion[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [showInstall, setShowInstall] = useState(false);
  const [extPanel, setExtPanel] = useState<PhpVersion | null>(null);
  const [removing, setRemoving] = useState<string | null>(null);
  const [removeError, setRemoveError] = useState("");

  const load = async () => {
    setLoading(true);
    setError("");
    try {
      const data = await api.get<PhpVersion[]>("/php/versions");
      setVersions(data);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to load PHP versions");
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => { load(); }, []);

  const handleRemove = async (v: PhpVersion) => {
    if (!confirm(`Remove PHP ${v.version}? This cannot be undone.`)) return;
    setRemoving(v.version);
    setRemoveError("");
    try {
      await api.delete(`/php/versions/${v.version}`);
      await load();
    } catch (e) {
      setRemoveError(e instanceof Error ? e.message : "Remove failed");
    } finally {
      setRemoving(null);
    }
  };

  const installedVersions = versions.map((v) => v.version);

  return (
    <div className="p-6 lg:p-8">
      <div className="flex items-center justify-between mb-6">
        <div>
          <h1 className="text-xs font-medium text-dark-300 uppercase font-mono tracking-widest">
            PHP Versions
          </h1>
          <p className="text-sm text-dark-300 mt-1">
            Manage installed PHP versions and extensions for this server.
          </p>
        </div>
        <button
          type="button"
          onClick={() => setShowInstall(true)}
          className="px-4 py-2 bg-rust-500 hover:bg-rust-600 text-white rounded-lg text-sm font-medium transition-colors"
        >
          Install PHP Version
        </button>
      </div>

      {error && (
        <div className="mb-4 px-4 py-3 bg-danger-500/10 border border-danger-500/20 rounded-lg text-sm text-danger-400">
          {error}
        </div>
      )}
      {removeError && (
        <div className="mb-4 px-4 py-3 bg-danger-500/10 border border-danger-500/20 rounded-lg text-sm text-danger-400">
          {removeError}
        </div>
      )}

      {loading && (
        <div className="animate-pulse space-y-3">
          {[1, 2].map((i) => (
            <div key={i} className="h-24 bg-dark-800 rounded-lg border border-dark-600" />
          ))}
        </div>
      )}

      {!loading && versions.length === 0 && (
        <div className="text-center py-16 bg-dark-800 rounded-lg border border-dark-600">
          <p className="text-dark-200 font-medium">No PHP versions installed</p>
          <p className="text-dark-300 text-sm mt-1">
            Click &quot;Install PHP Version&quot; to add your first version.
          </p>
        </div>
      )}

      {!loading && versions.length > 0 && (
        <div className="space-y-4">
          {versions.map((v) => {
            const VISIBLE_EXT_COUNT = 6;
            const visibleExts = v.extensions.slice(0, VISIBLE_EXT_COUNT);
            const extraCount = v.extensions.length - VISIBLE_EXT_COUNT;

            return (
              <div
                key={v.id}
                className="bg-dark-800 border border-dark-600 rounded-lg p-5"
              >
                <div className="flex items-start justify-between">
                  <div className="flex items-center gap-3">
                    <span className="text-lg font-mono font-semibold text-dark-50">
                      PHP {v.version}
                    </span>
                    <StatusBadge status={v.status} />
                    <span className="text-xs text-dark-400 bg-dark-700 px-2 py-0.5 rounded">
                      {v.install_method}
                    </span>
                  </div>
                  <div className="flex items-center gap-2">
                    <button
                      type="button"
                      onClick={() => setExtPanel(v)}
                      className="px-3 py-1.5 text-xs font-medium text-dark-200 bg-dark-700 hover:bg-dark-600 rounded-lg transition-colors"
                    >
                      Extensions
                    </button>
                    <button
                      type="button"
                      onClick={() => handleRemove(v)}
                      disabled={removing === v.version || v.status === "installing" || v.status === "removing"}
                      title={v.status === "active" ? "" : "Cannot remove — version is not active"}
                      className="px-3 py-1.5 text-xs font-medium text-danger-400 bg-danger-500/10 hover:bg-danger-500/20 rounded-lg transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
                    >
                      {removing === v.version ? "Removing..." : "Remove"}
                    </button>
                  </div>
                </div>

                {v.extensions.length > 0 && (
                  <div className="mt-3 flex flex-wrap gap-1.5">
                    {visibleExts.map((ext) => (
                      <span
                        key={ext}
                        className="text-xs px-2 py-0.5 bg-dark-700 text-dark-300 rounded font-mono"
                      >
                        {ext}
                      </span>
                    ))}
                    {extraCount > 0 && (
                      <button
                        type="button"
                        onClick={() => setExtPanel(v)}
                        className="text-xs px-2 py-0.5 bg-dark-700 text-rust-400 rounded"
                      >
                        +{extraCount} more
                      </button>
                    )}
                  </div>
                )}

                {v.status === "error" && v.error_message && (
                  <p className="mt-2 text-xs text-danger-400">{v.error_message}</p>
                )}
              </div>
            );
          })}
        </div>
      )}

      {showInstall && (
        <InstallModal
          installedVersions={installedVersions}
          onClose={() => setShowInstall(false)}
          onRefresh={load}
        />
      )}
      {extPanel && (
        <ExtensionsPanel
          version={extPanel.version}
          installed={extPanel.extensions}
          onClose={() => setExtPanel(null)}
          onRefresh={load}
        />
      )}
    </div>
  );
}
