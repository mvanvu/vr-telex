//! The input contexts of one client connection. Pure, no I/O.
//!
//! Each connection keeps its own table, so a path is found only by the
//! connection that created it: a call from anyone else on that path finds
//! nothing and is refused (SEC-9), whatever the path's number.

use std::collections::HashMap;

use ime_core::CtxId;

/// Where fcitx5 puts every input context, whichever input-method path created it.
pub(crate) const IC_PREFIX: &str = "/org/freedesktop/portal/inputcontext/";

pub(crate) fn ic_path(n: u64) -> String {
    format!("{IC_PREFIX}{n}")
}

/// The contexts of one connection, at most `cap` of them (SEC-16).
pub(crate) struct Contexts {
    by_path: HashMap<String, CtxId>,
    cap: usize,
}

/// The connection already has as many contexts as it may.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Full;

impl Contexts {
    pub(crate) fn new(cap: usize) -> Self {
        Self {
            by_path: HashMap::new(),
            cap,
        }
    }

    pub(crate) fn has_room(&self) -> bool {
        self.by_path.len() < self.cap
    }

    pub(crate) fn insert(&mut self, path: String, id: CtxId) -> Result<(), Full> {
        if !self.has_room() {
            return Err(Full);
        }
        self.by_path.insert(path, id);
        Ok(())
    }

    /// The context at `path` when this connection created it.
    pub(crate) fn get(&self, path: &str) -> Option<CtxId> {
        self.by_path.get(path).copied()
    }

    pub(crate) fn remove(&mut self, path: &str) -> Option<CtxId> {
        self.by_path.remove(path)
    }

    /// Every context, emptying the table: the connection is gone.
    pub(crate) fn drain(&mut self) -> Vec<CtxId> {
        self.by_path.drain().map(|(_, id)| id).collect()
    }

    #[cfg(test)]
    pub(crate) fn len(&self) -> usize {
        self.by_path.len()
    }
}

#[cfg(test)]
mod tests {
    use ime_core::{Ime, MemoryStateStore, Mode};

    use super::*;

    fn ime() -> Ime {
        Ime::new(&MemoryStateStore::new(Mode::Vi))
    }

    #[test]
    fn a_path_is_found_only_by_the_connection_that_created_it() {
        let mut ime = ime();
        let mut a = Contexts::new(8);
        let b = Contexts::new(8);
        let id = ime.create_context();
        a.insert(ic_path(1), id).unwrap();

        assert_eq!(a.get(&ic_path(1)), Some(id));
        assert_eq!(
            b.get(&ic_path(1)),
            None,
            "foreign connection must not see it"
        );
        assert_eq!(a.get(&ic_path(2)), None);
        assert_eq!(a.get("/org/freedesktop/portal/inputcontext/1/"), None);
    }

    #[test]
    fn the_cap_refuses_one_more_context() {
        let mut ime = ime();
        let mut a = Contexts::new(2);
        a.insert(ic_path(1), ime.create_context()).unwrap();
        a.insert(ic_path(2), ime.create_context()).unwrap();
        assert!(!a.has_room());
        assert_eq!(a.insert(ic_path(3), ime.create_context()), Err(Full));
        assert_eq!(a.len(), 2);

        a.remove(&ic_path(1)).unwrap();
        assert!(a.has_room());
        a.insert(ic_path(3), ime.create_context()).unwrap();
    }

    #[test]
    fn drain_hands_back_every_context_once() {
        let mut ime = ime();
        let mut a = Contexts::new(8);
        let ids = [ime.create_context(), ime.create_context()];
        a.insert(ic_path(1), ids[0]).unwrap();
        a.insert(ic_path(2), ids[1]).unwrap();
        let mut drained = a.drain();
        drained.sort_by_key(|id| format!("{id:?}"));
        assert_eq!(drained.len(), 2);
        assert!(a.drain().is_empty());
        assert_eq!(a.get(&ic_path(1)), None);
    }

    #[test]
    fn paths_follow_the_fcitx5_layout() {
        assert_eq!(ic_path(7), "/org/freedesktop/portal/inputcontext/7");
    }
}
