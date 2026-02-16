import { useCallback, useRef, useState } from "react";
import { MosaicDirection, MosaicNode } from "react-mosaic-component";
import { getAgentById } from "../config/agents";
import { SavedWorkspace } from "../config/settings";
import { activeTab, AgentProfile, AgentStatus, PaneState, PaneTab, PaneType } from "../types/agent";

const MAX_TABS_PER_PANE = 10;
const MAX_PANES = 20;

interface AgentManagerState {
  panes: Map<string, PaneState>;
  activePaneId: string;
  layout: MosaicNode<string> | null;
}

export interface AgentManager {
  panes: Map<string, PaneState>;
  activePaneId: string;
  layout: MosaicNode<string> | null;
  paneCount: number;
  spawnAgent: (profileId: string) => string;
  spawnBrowser: () => string;
  spawnTerminal: () => string;
  splitPane: (direction: MosaicDirection, paneId: string) => string | null;
  closePane: (paneId: string) => void;
  focusPane: (paneId: string) => void;
  navigateToPane: (direction: "left" | "right" | "up" | "down") => void;
  resizePane: (direction: "left" | "right" | "up" | "down", tickPercent?: number) => void;
  setLayout: (layout: MosaicNode<string> | null) => void;
  restartAgent: (paneId: string) => void;
  stopAgent: (paneId: string) => void;
  updateAgentStatus: (paneId: string, status: AgentStatus) => void;
  addTabToPane: (paneId: string, type: PaneType, profileId?: string) => string | null;
  removeTabFromPane: (paneId: string, tabId: string) => void;
  switchTab: (paneId: string, index: number) => void;
  nextTab: (paneId: string) => void;
  prevTab: (paneId: string) => void;
  createMosaicNode: (profileId?: string) => string;
  getAgentProfile: (paneId: string) => AgentProfile | undefined;
  restoreWorkspace: (
    panes: Array<{ id: string; tabs: Array<{ id: string; type: PaneType; profileId?: string }> }>,
    layout: MosaicNode<string> | null,
  ) => void;
}

function isParentNode(node: MosaicNode<string>): node is Exclude<MosaicNode<string>, string> {
  return typeof node !== "string";
}

function parseIdNumber(id: string): number | null {
  const match = id.match(/^(?:pane|tab)-(\d+)$/);
  if (!match) {
    return null;
  }

  const parsed = Number.parseInt(match[1], 10);
  return Number.isNaN(parsed) ? null : parsed;
}

function createTitle(type: PaneType, id: string, profileId?: string): string {
  const idNumber = parseIdNumber(id);
  const titleSuffix = idNumber === null ? id : String(idNumber);

  if (type === "browser") {
    return `Browser ${titleSuffix}`;
  }

  if (type === "agent" && profileId) {
    return getAgentById(profileId)?.name ?? `Agent ${titleSuffix}`;
  }

  return `Terminal ${titleSuffix}`;
}

function createPaneTab(id: string, type: PaneType, profileId?: string): PaneTab {
  if (type === "agent" && profileId) {
    return {
      id,
      type,
      title: createTitle(type, id, profileId),
      agent: {
        id,
        profileId,
        status: "starting",
        startedAt: Date.now(),
        exitCode: null,
        restartCount: 0,
      },
    };
  }

  return { id, type, title: createTitle(type, id) };
}

function createPaneState(paneId: string, tabId: string, type: PaneType, profileId?: string): PaneState {
  return {
    id: paneId,
    tabs: [createPaneTab(tabId, type, profileId)],
    activeTabIndex: 0,
  };
}

function clampTabIndex(index: number, tabCount: number): number {
  if (tabCount <= 0) {
    return 0;
  }

  return Math.min(tabCount - 1, Math.max(0, index));
}

function resolveActivePaneTab(pane: PaneState): { pane: PaneState; tab: PaneTab; index: number } | null {
  if (pane.tabs.length === 0) {
    return null;
  }

  const index = clampTabIndex(pane.activeTabIndex, pane.tabs.length);
  const normalizedPane = index === pane.activeTabIndex ? pane : { ...pane, activeTabIndex: index };

  return {
    pane: normalizedPane,
    tab: activeTab(normalizedPane),
    index,
  };
}

function replaceTabAtIndex(pane: PaneState, index: number, tab: PaneTab): PaneState {
  const nextTabs = pane.tabs.slice();
  nextTabs[index] = tab;

  return {
    ...pane,
    tabs: nextTabs,
  };
}

function insertSplit(
  node: MosaicNode<string>,
  targetId: string,
  newId: string,
  direction: MosaicDirection,
): MosaicNode<string> | null {
  if (!isParentNode(node)) {
    if (node !== targetId) {
      return null;
    }

    return {
      direction,
      first: node,
      second: newId,
      splitPercentage: 50,
    };
  }

  const nextFirst = insertSplit(node.first, targetId, newId, direction);
  if (nextFirst !== null) {
    return { ...node, first: nextFirst };
  }

  const nextSecond = insertSplit(node.second, targetId, newId, direction);
  if (nextSecond !== null) {
    return { ...node, second: nextSecond };
  }

  return null;
}

function removePaneNode(node: MosaicNode<string>, targetId: string): MosaicNode<string> | null {
  if (!isParentNode(node)) {
    return node === targetId ? null : node;
  }

  const nextFirst = removePaneNode(node.first, targetId);
  const nextSecond = removePaneNode(node.second, targetId);

  if (nextFirst === null && nextSecond === null) {
    return null;
  }
  if (nextFirst === null) {
    return nextSecond;
  }
  if (nextSecond === null) {
    return nextFirst;
  }

  return {
    ...node,
    first: nextFirst,
    second: nextSecond,
  };
}

function findPathToPane(
  node: MosaicNode<string>,
  paneId: string,
  path: Array<"first" | "second"> = [],
): Array<"first" | "second"> | null {
  if (!isParentNode(node)) {
    return node === paneId ? path : null;
  }

  const firstPath = findPathToPane(node.first, paneId, [...path, "first"]);
  if (firstPath !== null) {
    return firstPath;
  }

  return findPathToPane(node.second, paneId, [...path, "second"]);
}

function getNodeAtPath(node: MosaicNode<string>, path: Array<"first" | "second">): MosaicNode<string> {
  let current = node;

  for (const branch of path) {
    if (!isParentNode(current)) {
      return current;
    }

    current = current[branch];
  }

  return current;
}

function selectBoundaryLeaf(node: MosaicNode<string>, direction: "left" | "right" | "up" | "down"): string {
  if (!isParentNode(node)) {
    return node;
  }

  if (direction === "left" || direction === "up") {
    return selectBoundaryLeaf(node.second, direction);
  }

  return selectBoundaryLeaf(node.first, direction);
}

function findAdjacentPane(
  root: MosaicNode<string>,
  sourcePaneId: string,
  direction: "left" | "right" | "up" | "down",
): string | null {
  const sourcePath = findPathToPane(root, sourcePaneId);
  if (sourcePath === null) {
    return null;
  }

  for (let i = sourcePath.length - 1; i >= 0; i -= 1) {
    const ancestorPath = sourcePath.slice(0, i);
    const ancestor = getNodeAtPath(root, ancestorPath);

    if (!isParentNode(ancestor)) {
      continue;
    }

    const branch = sourcePath[i];

    if (direction === "left" && ancestor.direction === "row" && branch === "second") {
      return selectBoundaryLeaf(ancestor.first, direction);
    }
    if (direction === "right" && ancestor.direction === "row" && branch === "first") {
      return selectBoundaryLeaf(ancestor.second, direction);
    }
    if (direction === "up" && ancestor.direction === "column" && branch === "second") {
      return selectBoundaryLeaf(ancestor.first, direction);
    }
    if (direction === "down" && ancestor.direction === "column" && branch === "first") {
      return selectBoundaryLeaf(ancestor.second, direction);
    }
  }

  return null;
}

function getFirstLeaf(node: MosaicNode<string> | null): string | null {
  if (node === null) {
    return null;
  }

  if (!isParentNode(node)) {
    return node;
  }

  return getFirstLeaf(node.first);
}

function clampSplitPercentage(value: number): number {
  return Math.min(90, Math.max(10, value));
}

function adjustSplitAtPath(
  root: MosaicNode<string>,
  ancestorPath: Array<"first" | "second">,
  delta: number,
): MosaicNode<string> {
  const updateNode = (node: MosaicNode<string>, depth: number): MosaicNode<string> => {
    if (depth === ancestorPath.length) {
      if (!isParentNode(node)) {
        return node;
      }

      const currentSplit = node.splitPercentage ?? 50;
      return {
        ...node,
        splitPercentage: clampSplitPercentage(currentSplit + delta),
      };
    }

    if (!isParentNode(node)) {
      return node;
    }

    const branch = ancestorPath[depth];
    if (branch === "first") {
      return {
        ...node,
        first: updateNode(node.first, depth + 1),
      };
    }

    return {
      ...node,
      second: updateNode(node.second, depth + 1),
    };
  };

  return updateNode(root, 0);
}

function collectLeafIds(node: MosaicNode<string> | null): Set<string> {
  const ids = new Set<string>();
  if (node === null) return ids;
  if (typeof node === "string") {
    ids.add(node);
    return ids;
  }
  for (const id of collectLeafIds(node.first)) ids.add(id);
  for (const id of collectLeafIds(node.second)) ids.add(id);
  return ids;
}

function buildStateFromSaved(saved: SavedWorkspace): { state: AgentManagerState; maxId: number } {
  const panes = new Map<string, PaneState>();
  let maxId = 1;

  const layout = saved.layout ?? saved.panes[0]?.id ?? null;
  const layoutIds = collectLeafIds(layout);

  for (const p of saved.panes) {
    if (layoutIds.size > 0 && !layoutIds.has(p.id)) {
      continue;
    }

    const num = parseIdNumber(p.id);
    if (num !== null) maxId = Math.max(maxId, num);

    const tabs = p.tabs.map((t) => {
      const tNum = parseIdNumber(t.id);
      if (tNum !== null) maxId = Math.max(maxId, tNum);
      return createPaneTab(t.id, t.type, t.profileId);
    });

    if (tabs.length === 0) {
      maxId += 1;
      tabs.push(createPaneTab(`tab-${maxId}`, "terminal"));
    }

    panes.set(p.id, {
      id: p.id,
      tabs,
      activeTabIndex: clampTabIndex(p.activeTabIndex ?? 0, tabs.length),
    });
  }

  const firstLeaf = layout ? getFirstLeaf(layout) : null;
  const activePaneId =
    saved.activePaneId && panes.has(saved.activePaneId)
      ? saved.activePaneId
      : firstLeaf && panes.has(firstLeaf)
        ? firstLeaf
        : saved.panes[0]?.id ?? "pane-1";

  return {
    state: { panes, activePaneId, layout },
    maxId,
  };
}

export function useAgentManager(initialWorkspace?: SavedWorkspace | null): AgentManager {
  const nextIdRef = useRef(2);

  const [state, setState] = useState<AgentManagerState>(() => {
    if (initialWorkspace && initialWorkspace.panes.length > 0) {
      const { state: restored, maxId } = buildStateFromSaved(initialWorkspace);
      nextIdRef.current = maxId;
      return restored;
    }

    const initialPaneId = "pane-1";
    const initialPane = createPaneState(initialPaneId, "tab-2", "terminal");

    return {
      panes: new Map([[initialPaneId, initialPane]]),
      activePaneId: initialPaneId,
      layout: initialPaneId,
    };
  });

  const nextPaneId = useCallback((): string => {
    nextIdRef.current += 1;
    return `pane-${nextIdRef.current}`;
  }, []);

  const nextTabId = useCallback((): string => {
    nextIdRef.current += 1;
    return `tab-${nextIdRef.current}`;
  }, []);

  const createMosaicNode = useCallback(
    (profileId?: string): string => {
      const paneId = nextPaneId();
      const tabId = nextTabId();
      const profile = profileId ? getAgentById(profileId) : undefined;
      const pane = profile && profile.id !== "terminal"
        ? createPaneState(paneId, tabId, "agent", profile.id)
        : createPaneState(paneId, tabId, "terminal");

      setState((prev) => {
        const nextPanes = new Map(prev.panes);
        nextPanes.set(paneId, pane);
        return { ...prev, panes: nextPanes };
      });

      return paneId;
    },
    [nextPaneId, nextTabId],
  );

  const spawnPane = useCallback(
    (pane: PaneState): string => {
      setState((prev) => {
        if (prev.panes.size >= MAX_PANES) {
          return prev;
        }

        const nextPanes = new Map(prev.panes);
        nextPanes.set(pane.id, pane);

        if (prev.layout === null) {
          return {
            panes: nextPanes,
            activePaneId: pane.id,
            layout: pane.id,
          };
        }

        const nextLayout =
          insertSplit(prev.layout, prev.activePaneId, pane.id, "row") ?? {
            direction: "row",
            first: prev.layout,
            second: pane.id,
            splitPercentage: 50,
          };

        return {
          panes: nextPanes,
          activePaneId: pane.id,
          layout: nextLayout,
        };
      });

      return pane.id;
    },
    [],
  );

  const spawnAgent = useCallback(
    (profileId: string): string => {
      const paneId = nextPaneId();
      const tabId = nextTabId();

      if (profileId === "terminal") {
        return spawnPane(createPaneState(paneId, tabId, "terminal"));
      }

      const profile = getAgentById(profileId);

      if (!profile) {
        return spawnPane(createPaneState(paneId, tabId, "terminal"));
      }

      return spawnPane(createPaneState(paneId, tabId, "agent", profile.id));
    },
    [nextPaneId, nextTabId, spawnPane],
  );

  const spawnBrowser = useCallback((): string => {
    const paneId = nextPaneId();
    return spawnPane(createPaneState(paneId, nextTabId(), "browser"));
  }, [nextPaneId, nextTabId, spawnPane]);

  const spawnTerminal = useCallback((): string => {
    const paneId = nextPaneId();
    return spawnPane(createPaneState(paneId, nextTabId(), "terminal"));
  }, [nextPaneId, nextTabId, spawnPane]);

  const splitPane = useCallback(
    (direction: MosaicDirection, paneId: string): string | null => {
      const targetPane = state.panes.get(paneId);
      const resolvedTarget = targetPane ? resolveActivePaneTab(targetPane) : null;

      if (!resolvedTarget) {
        return null;
      }

      const sourceTab = resolvedTarget.tab;
      const newPaneId = nextPaneId();
      const newTabId = nextTabId();
      const newPane =
        sourceTab.type === "agent" && sourceTab.agent
          ? createPaneState(newPaneId, newTabId, "agent", sourceTab.agent.profileId)
          : createPaneState(newPaneId, newTabId, sourceTab.type);

      setState((prev) => {
        if (prev.layout === null || !prev.panes.has(paneId)) {
          return prev;
        }

        const nextPanes = new Map(prev.panes);
        nextPanes.set(newPaneId, newPane);

        const nextLayout =
          insertSplit(prev.layout, paneId, newPaneId, direction) ?? {
            direction,
            first: prev.layout,
            second: newPaneId,
            splitPercentage: 50,
          };

        return {
          panes: nextPanes,
          activePaneId: newPaneId,
          layout: nextLayout,
        };
      });

      return newPaneId;
    },
    [nextPaneId, nextTabId, state.panes],
  );

  const closePane = useCallback(
    (paneId: string): void => {
      setState((prev) => {
        if (!prev.panes.has(paneId)) {
          return prev;
        }

        const nextPanes = new Map(prev.panes);
        nextPanes.delete(paneId);

        const nextLayout = prev.layout === null ? null : removePaneNode(prev.layout, paneId);

        if (nextPanes.size === 0 || nextLayout === null) {
          const fallbackPaneId = nextPaneId();
          const fallbackPane = createPaneState(fallbackPaneId, nextTabId(), "terminal");
          return {
            panes: new Map([[fallbackPaneId, fallbackPane]]),
            activePaneId: fallbackPaneId,
            layout: fallbackPaneId,
          };
        }

        const adjacentPane =
          prev.layout === null
            ? null
            : findAdjacentPane(prev.layout, paneId, "right") ??
              findAdjacentPane(prev.layout, paneId, "left") ??
              findAdjacentPane(prev.layout, paneId, "down") ??
              findAdjacentPane(prev.layout, paneId, "up");

        const firstLeaf = getFirstLeaf(nextLayout);
        const nextActivePaneId =
          prev.activePaneId === paneId ? adjacentPane ?? firstLeaf ?? prev.activePaneId : prev.activePaneId;

        return {
          panes: nextPanes,
          activePaneId: nextPanes.has(nextActivePaneId) ? nextActivePaneId : (firstLeaf ?? prev.activePaneId),
          layout: nextLayout,
        };
      });
    },
    [nextPaneId, nextTabId],
  );

  const focusPane = useCallback((paneId: string): void => {
    setState((prev) => {
      if (!prev.panes.has(paneId) || prev.activePaneId === paneId) {
        return prev;
      }

      return { ...prev, activePaneId: paneId };
    });
  }, []);

  const navigateToPane = useCallback((direction: "left" | "right" | "up" | "down"): void => {
    setState((prev) => {
      if (prev.layout === null) {
        return prev;
      }

      const adjacentPaneId = findAdjacentPane(prev.layout, prev.activePaneId, direction);
      if (adjacentPaneId === null) {
        return prev;
      }

      return {
        ...prev,
        activePaneId: adjacentPaneId,
      };
    });
  }, []);

  const resizePane = useCallback((direction: "left" | "right" | "up" | "down", tickPercent = 5): void => {
    setState((prev) => {
      if (prev.layout === null) {
        return prev;
      }

      const activePath = findPathToPane(prev.layout, prev.activePaneId);
      if (activePath === null) {
        return prev;
      }

      const axisDirection = direction === "left" || direction === "right" ? "row" : "column";
      const delta = direction === "left" || direction === "up" ? -Math.abs(tickPercent) : Math.abs(tickPercent);

      for (let i = activePath.length - 1; i >= 0; i -= 1) {
        const ancestorPath = activePath.slice(0, i);
        const ancestor = getNodeAtPath(prev.layout, ancestorPath);
        if (!isParentNode(ancestor) || ancestor.direction !== axisDirection) {
          continue;
        }

        return {
          ...prev,
          layout: adjustSplitAtPath(prev.layout, ancestorPath, delta),
        };
      }

      return prev;
    });
  }, []);

  const setLayout = useCallback((layout: MosaicNode<string> | null): void => {
    setState((prev) => {
      if (layout === null) {
        const firstPaneId = prev.panes.keys().next().value;
        if (!firstPaneId) {
          return prev;
        }

        return {
          ...prev,
          layout: firstPaneId,
          activePaneId: prev.panes.has(prev.activePaneId) ? prev.activePaneId : firstPaneId,
        };
      }

      const existingPath = findPathToPane(layout, prev.activePaneId);
      const firstLeaf = getFirstLeaf(layout);

      return {
        ...prev,
        layout,
        activePaneId: existingPath !== null ? prev.activePaneId : (firstLeaf ?? prev.activePaneId),
      };
    });
  }, []);

  const addTabToPane = useCallback(
    (paneId: string, type: PaneType, profileId?: string): string | null => {
      const pane = state.panes.get(paneId);
      if (!pane || pane.tabs.length >= MAX_TABS_PER_PANE) {
        return null;
      }

      const tabId = nextTabId();
      const tab = createPaneTab(tabId, type, profileId);

      setState((prev) => {
        const currentPane = prev.panes.get(paneId);
        if (!currentPane || currentPane.tabs.length >= MAX_TABS_PER_PANE) {
          return prev;
        }

        const nextPanes = new Map(prev.panes);
        nextPanes.set(paneId, {
          ...currentPane,
          tabs: [...currentPane.tabs, tab],
          activeTabIndex: currentPane.tabs.length,
        });

        return {
          ...prev,
          panes: nextPanes,
          activePaneId: paneId,
        };
      });

      return tabId;
    },
    [nextTabId, state.panes],
  );

  const removeTabFromPane = useCallback(
    (paneId: string, tabId: string): void => {
      const pane = state.panes.get(paneId);
      if (!pane) {
        return;
      }

      const tabIndex = pane.tabs.findIndex((tab) => tab.id === tabId);
      if (tabIndex === -1) {
        return;
      }

      if (pane.tabs.length === 1) {
        closePane(paneId);
        return;
      }

      setState((prev) => {
        const targetPane = prev.panes.get(paneId);
        if (!targetPane) {
          return prev;
        }

        const removeIndex = targetPane.tabs.findIndex((tab) => tab.id === tabId);
        if (removeIndex === -1) {
          return prev;
        }

        if (targetPane.tabs.length === 1) {
          return prev;
        }

        const nextTabs = targetPane.tabs.filter((tab) => tab.id !== tabId);
        let nextActiveTabIndex = targetPane.activeTabIndex;

        if (removeIndex < targetPane.activeTabIndex) {
          nextActiveTabIndex = targetPane.activeTabIndex - 1;
        } else if (removeIndex === targetPane.activeTabIndex) {
          nextActiveTabIndex = Math.max(0, targetPane.activeTabIndex - 1);
        }

        nextActiveTabIndex = clampTabIndex(nextActiveTabIndex, nextTabs.length);

        const nextPanes = new Map(prev.panes);
        nextPanes.set(paneId, {
          ...targetPane,
          tabs: nextTabs,
          activeTabIndex: nextActiveTabIndex,
        });

        return {
          ...prev,
          panes: nextPanes,
          activePaneId: paneId,
        };
      });
    },
    [closePane, state.panes],
  );

  const switchTab = useCallback((paneId: string, index: number): void => {
    setState((prev) => {
      const pane = prev.panes.get(paneId);
      if (!pane || pane.tabs.length === 0) {
        return prev;
      }

      const nextIndex = clampTabIndex(index, pane.tabs.length);
      if (pane.activeTabIndex === nextIndex && prev.activePaneId === paneId) {
        return prev;
      }

      const nextPanes = new Map(prev.panes);
      nextPanes.set(paneId, {
        ...pane,
        activeTabIndex: nextIndex,
      });

      return {
        ...prev,
        panes: nextPanes,
        activePaneId: paneId,
      };
    });
  }, []);

  const nextTab = useCallback((paneId: string): void => {
    setState((prev) => {
      const pane = prev.panes.get(paneId);
      if (!pane || pane.tabs.length === 0) {
        return prev;
      }

      const activeIndex = clampTabIndex(pane.activeTabIndex, pane.tabs.length);
      const nextIndex = (activeIndex + 1) % pane.tabs.length;

      if (activeIndex === nextIndex && prev.activePaneId === paneId) {
        return prev;
      }

      const nextPanes = new Map(prev.panes);
      nextPanes.set(paneId, {
        ...pane,
        activeTabIndex: nextIndex,
      });

      return {
        ...prev,
        panes: nextPanes,
        activePaneId: paneId,
      };
    });
  }, []);

  const prevTab = useCallback((paneId: string): void => {
    setState((prev) => {
      const pane = prev.panes.get(paneId);
      if (!pane || pane.tabs.length === 0) {
        return prev;
      }

      const activeIndex = clampTabIndex(pane.activeTabIndex, pane.tabs.length);
      const nextIndex = (activeIndex - 1 + pane.tabs.length) % pane.tabs.length;

      if (activeIndex === nextIndex && prev.activePaneId === paneId) {
        return prev;
      }

      const nextPanes = new Map(prev.panes);
      nextPanes.set(paneId, {
        ...pane,
        activeTabIndex: nextIndex,
      });

      return {
        ...prev,
        panes: nextPanes,
        activePaneId: paneId,
      };
    });
  }, []);

  const restartAgent = useCallback((paneId: string): void => {
    setState((prev) => {
      const pane = prev.panes.get(paneId);
      const resolvedPane = pane ? resolveActivePaneTab(pane) : null;

      if (!resolvedPane || resolvedPane.tab.type !== "agent" || !resolvedPane.tab.agent) {
        return prev;
      }

      const agent = resolvedPane.tab.agent;
      const { pane: activePane, tab, index } = resolvedPane;
      const nextPanes = new Map(prev.panes);
      nextPanes.set(
        paneId,
        replaceTabAtIndex(activePane, index, {
          ...tab,
          agent: {
            ...agent,
            status: "starting",
            exitCode: null,
            startedAt: Date.now(),
            restartCount: agent.restartCount + 1,
          },
        }),
      );

      return { ...prev, panes: nextPanes };
    });
  }, []);

  const stopAgent = useCallback((paneId: string): void => {
    setState((prev) => {
      const pane = prev.panes.get(paneId);
      const resolvedPane = pane ? resolveActivePaneTab(pane) : null;

      if (!resolvedPane || resolvedPane.tab.type !== "agent" || !resolvedPane.tab.agent) {
        return prev;
      }

      const agent = resolvedPane.tab.agent;
      const { pane: activePane, tab, index } = resolvedPane;
      const nextPanes = new Map(prev.panes);
      nextPanes.set(
        paneId,
        replaceTabAtIndex(activePane, index, {
          ...tab,
          agent: {
            ...agent,
            status: "stopped",
          },
        }),
      );

      return { ...prev, panes: nextPanes };
    });
  }, []);

  const updateAgentStatus = useCallback((paneId: string, status: AgentStatus): void => {
    setState((prev) => {
      const pane = prev.panes.get(paneId);
      const resolvedPane = pane ? resolveActivePaneTab(pane) : null;

      if (!resolvedPane || resolvedPane.tab.type !== "agent" || !resolvedPane.tab.agent || resolvedPane.tab.agent.status === "stopped") {
        return prev;
      }

      const agent = resolvedPane.tab.agent;
      if (agent.status === status) {
        return prev;
      }

      const { pane: activePane, tab, index } = resolvedPane;
      const nextPanes = new Map(prev.panes);
      nextPanes.set(
        paneId,
        replaceTabAtIndex(activePane, index, {
          ...tab,
          agent: {
            ...agent,
            status,
            startedAt: status === "starting" ? Date.now() : agent.startedAt,
          },
        }),
      );

      return { ...prev, panes: nextPanes };
    });
  }, []);

  const getAgentProfile = useCallback(
    (paneId: string): AgentProfile | undefined => {
      const pane = state.panes.get(paneId);
      const resolvedPane = pane ? resolveActivePaneTab(pane) : null;

      if (!resolvedPane || resolvedPane.tab.type !== "agent" || !resolvedPane.tab.agent) {
        return undefined;
      }

      return getAgentById(resolvedPane.tab.agent.profileId);
    },
    [state.panes],
  );

  const restoreWorkspace = useCallback(
    (
      panes: Array<{ id: string; tabs: Array<{ id: string; type: PaneType; profileId?: string }> }>,
      layout: MosaicNode<string> | null,
    ): void => {
      if (panes.length === 0) {
        return;
      }

      const nextPanes = new Map<string, PaneState>();
      let maxId = 1;
      const effectiveLayout = layout ?? panes[0].id;
      const layoutIds = collectLeafIds(effectiveLayout);

      panes.forEach((pane) => {
        if (layoutIds.size > 0 && !layoutIds.has(pane.id)) {
          return;
        }

        const paneNumber = parseIdNumber(pane.id);
        if (paneNumber !== null) {
          maxId = Math.max(maxId, paneNumber);
        }

        const tabs = pane.tabs.map((tab) => {
          const tabNumber = parseIdNumber(tab.id);
          if (tabNumber !== null) {
            maxId = Math.max(maxId, tabNumber);
          }

          return createPaneTab(tab.id, tab.type, tab.profileId);
        });

        if (tabs.length === 0) {
          maxId += 1;
          tabs.push(createPaneTab(`tab-${maxId}`, "terminal"));
        }

        nextPanes.set(pane.id, {
          id: pane.id,
          tabs,
          activeTabIndex: 0,
        });
      });

      nextIdRef.current = maxId;

      const firstLeaf = getFirstLeaf(effectiveLayout);

      setState({
        panes: nextPanes,
        layout: effectiveLayout,
        activePaneId: firstLeaf && nextPanes.has(firstLeaf) ? firstLeaf : panes[0].id,
      });
    },
    [],
  );

  return {
    panes: state.panes,
    activePaneId: state.activePaneId,
    layout: state.layout,
    paneCount: state.panes.size,
    spawnAgent,
    spawnBrowser,
    spawnTerminal,
    splitPane,
    closePane,
    focusPane,
    navigateToPane,
    resizePane,
    setLayout,
    restartAgent,
    stopAgent,
    updateAgentStatus,
    addTabToPane,
    removeTabFromPane,
    switchTab,
    nextTab,
    prevTab,
    createMosaicNode,
    getAgentProfile,
    restoreWorkspace,
  };
}
