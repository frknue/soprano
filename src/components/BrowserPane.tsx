import { memo, useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { ArrowRight, ChevronLeft, RefreshCw, SquareTerminal } from "lucide-react";

interface BrowserPaneProps {
  paneId: string;
  isActive: boolean;
  isVisible: boolean;
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
  isVisible,
  initialUrl = "https://www.google.com",
}: BrowserPaneProps) {
  const viewportRef = useRef<HTMLDivElement>(null);
  const [urlInput, setUrlInput] = useState(initialUrl);
  const createdRef = useRef(false);
  const webviewLabel = `browser-${paneId.replace(/[^a-zA-Z0-9-_]/g, "-")}`;

  useEffect(() => {
    const el = viewportRef.current;
    if (!el) {
      return;
    }

    const rect = el.getBoundingClientRect();
    invoke("create_browser", {
      label: webviewLabel,
      url: initialUrl,
      x: rect.width > 0 ? rect.x : -10000,
      y: rect.height > 0 ? rect.y : -10000,
      width: Math.max(rect.width, 1),
      height: Math.max(rect.height, 1),
    })
      .then(() => {
        createdRef.current = true;
      })
      .catch(() => {});

    return () => {
      createdRef.current = false;
      invoke("close_browser", { label: webviewLabel }).catch(() => {});
    };
  }, [webviewLabel, initialUrl]);

  useEffect(() => {
    if (!createdRef.current) {
      return;
    }

    if (!isVisible) {
      invoke("resize_browser", {
        label: webviewLabel,
        x: -10000,
        y: -10000,
        width: 1,
        height: 1,
      }).catch(() => {});
      return;
    }

    const el = viewportRef.current;
    if (!el) {
      return;
    }
    const rect = el.getBoundingClientRect();
    if (rect.width > 0 && rect.height > 0) {
      invoke("resize_browser", {
        label: webviewLabel,
        x: rect.x,
        y: rect.y,
        width: rect.width,
        height: rect.height,
      }).catch(() => {});
    }
  }, [isVisible, webviewLabel]);

  useEffect(() => {
    const el = viewportRef.current;
    if (!el) {
      return;
    }

    let rafId: number | null = null;
    const observer = new ResizeObserver(() => {
      if (!createdRef.current || !isVisible) {
        return;
      }
      if (rafId !== null) return;
      rafId = requestAnimationFrame(() => {
        rafId = null;
        const rect = el.getBoundingClientRect();
        if (rect.width <= 0 || rect.height <= 0) {
          return;
        }
        invoke("resize_browser", {
          label: webviewLabel,
          x: rect.x,
          y: rect.y,
          width: rect.width,
          height: rect.height,
        }).catch(() => {});
      });
    });

    observer.observe(el);
    return () => {
      observer.disconnect();
      if (rafId !== null) cancelAnimationFrame(rafId);
    };
  }, [webviewLabel, isVisible]);

  const navigate = (): void => {
    const next = normalizeUrl(urlInput.trim());
    setUrlInput(next);
    if (createdRef.current) {
      invoke("navigate_browser", { label: webviewLabel, url: next }).catch(() => {});
    }
  };

  const goBack = (): void => {
    if (createdRef.current) {
      invoke("browser_go_back", { label: webviewLabel }).catch(() => {});
    }
  };

  const refresh = (): void => {
    if (createdRef.current) {
      invoke("browser_refresh", { label: webviewLabel }).catch(() => {});
    }
  };

  const toggleDevtools = (): void => {
    if (createdRef.current) {
      invoke("browser_devtools", { label: webviewLabel }).catch(() => {});
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
        <button className="browser-button" onClick={toggleDevtools} title="Toggle DevTools" type="button">
          <SquareTerminal size={14} />
        </button>
      </div>
      <div className="browser-viewport" ref={viewportRef} />
    </div>
  );
});
