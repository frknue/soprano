import { useCallback, useRef, useState } from "react";

export interface AppNotification {
  id: string;
  title: string;
  message: string;
  type: "info" | "success" | "error" | "warning";
  timestamp: number;
  paneId?: string;
  dismissed: boolean;
}

const MAX_NOTIFICATIONS = 50;
const AUTO_DISMISS_MS = 10_000;

export function useNotifications(): {
  notifications: AppNotification[];
  notify: (title: string, message: string, type: AppNotification["type"], paneId?: string) => void;
  dismiss: (id: string) => void;
  dismissAll: () => void;
} {
  const [notifications, setNotifications] = useState<AppNotification[]>([]);
  const nextIdRef = useRef(0);
  const permissionRequestedRef = useRef(false);

  const dismiss = useCallback((id: string): void => {
    setNotifications((prev) =>
      prev.map((item) => {
        if (item.id !== id) {
          return item;
        }

        return {
          ...item,
          dismissed: true,
        };
      }),
    );
  }, []);

  const dismissAll = useCallback((): void => {
    setNotifications((prev) => prev.map((item) => ({ ...item, dismissed: true })));
  }, []);

  const notify = useCallback(
    (title: string, message: string, type: AppNotification["type"], paneId?: string): void => {
      nextIdRef.current += 1;
      const id = `notification-${nextIdRef.current}`;
      const timestamp = Date.now();

      setNotifications((prev) => {
        const next = [...prev, { id, title, message, type, timestamp, paneId, dismissed: false }];
        return next.length > MAX_NOTIFICATIONS ? next.slice(next.length - MAX_NOTIFICATIONS) : next;
      });

      if ("Notification" in window) {
        if (!permissionRequestedRef.current) {
          permissionRequestedRef.current = true;
          if (Notification.permission === "default") {
            void Notification.requestPermission();
          }
        }

        if (Notification.permission === "granted") {
          try {
            void new Notification(title, { body: message });
          } catch {
          }
        }
      }

      window.setTimeout(() => {
        dismiss(id);
      }, AUTO_DISMISS_MS);
    },
    [dismiss],
  );

  return {
    notifications,
    notify,
    dismiss,
    dismissAll,
  };
}
