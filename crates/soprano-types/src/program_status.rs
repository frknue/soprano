//! Values of the Program Status Protocol (OSC 7501, revision 0.4): what a program running in
//! a terminal says it is doing. `soprano-term` parses them out of the output.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProgramState {
    Idle,
    Working,
    Blocked,
    Done,
    Error,
    /// Removes the record (and its children); not a stored state.
    Clear,
}

/// Why a blocked program waits.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BlockedKind {
    Permission,
    Question,
    Auth,
}

/// One report (`OSC 7501;state=…:… ST`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProgramStatus {
    pub state: ProgramState,
    /// The record path; `None` addresses the root record.
    pub id: Option<String>,
    /// Only on `blocked`.
    pub kind: Option<BlockedKind>,
    /// Only on `working` and `blocked`.
    pub progress: Option<u8>,
    pub app: Option<String>,
    pub title: Option<String>,
    pub msg: Option<String>,
}
