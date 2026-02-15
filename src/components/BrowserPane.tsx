import { memo, useMemo, useRef, useState } from "react";
import { ArrowRight, ChevronLeft, RefreshCw } from "lucide-react";

interface BrowserPaneProps {
  paneId: string;
  isActive: boolean;
  initialUrl?: string;
}

function normalizeUrl(value: string): string {
  if (value.startsWith("http://") || value.startsWith("https://")) {
    return value;
  }

  return `https://${value}`;
}

export const BrowserPane = memo(function BrowserPane({
  paneId,
  isActive,
  initialUrl = "https://www.google.com",
}: BrowserPaneProps) {
  const iframeRef = useRef<HTMLIFrameElement | null>(null);
  const [urlInput, setUrlInput] = useState(initialUrl);
  const [url, setUrl] = useState(initialUrl);
  const [reloadToken, setReloadToken] = useState(0);

  const iframeKey = useMemo(() => `${paneId}-${reloadToken}-${url}`, [paneId, reloadToken, url]);

  const navigate = (): void => {
    const nextUrl = normalizeUrl(urlInput.trim());
    setUrlInput(nextUrl);
    setUrl(nextUrl);
  };

  const goBack = (): void => {
    try {
      iframeRef.current?.contentWindow?.history.back();
    } catch {
      setReloadToken((prev) => prev + 1);
    }
  };

  const refresh = (): void => {
    try {
      iframeRef.current?.contentWindow?.location.reload();
    } catch {
      setReloadToken((prev) => prev + 1);
    }
  };

  return (
    <div className={`pane browser-pane ${isActive ? "pane-active" : ""}`}>
      <div className="browser-toolbar">
        <button className="browser-button" onClick={goBack} title="Back" type="button">
          <ChevronLeft size={16} />
        </button>
        <button className="browser-button" onClick={refresh} title="Refresh" type="button">
          <RefreshCw size={14} />
        </button>
        <input
          className="browser-input"
          onChange={(event) => setUrlInput(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter") {
              event.preventDefault();
              navigate();
            }
          }}
          spellCheck={false}
          value={urlInput}
        />
        <button className="browser-button browser-go" onClick={navigate} title="Navigate" type="button">
          <ArrowRight size={14} />
        </button>
      </div>
      <iframe
        className="browser-frame"
        key={iframeKey}
        ref={iframeRef}
        sandbox="allow-forms allow-modals allow-popups allow-presentation allow-same-origin allow-scripts"
        src={url}
        title={`Browser ${paneId}`}
      />
    </div>
  );
});
