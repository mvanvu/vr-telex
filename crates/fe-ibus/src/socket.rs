//! The socket halves handed to the D-Bus library, with the limits it lacks.
//!
//! The library accepts messages up to the protocol maximum (128 MiB) and
//! buffers a handshake line of any length. A client is untrusted (SEC-15,
//! SEC-16), so both are capped here before anything is allocated for them.
//! File descriptors are never accepted: no method of this bus takes one.

use std::io;
use std::os::fd::OwnedFd;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use zbus::Message;
use zbus::connection::socket::{BoxedSplit, ReadHalf, Split, WriteHalf};
use zbus::export::async_trait::async_trait;
use zbus::fdo::ConnectionCredentials;

/// The fixed part of a message header: enough to know the message's length.
const FIXED_HEADER: usize = 16;
/// A SASL handshake is a few short lines.
const HANDSHAKE_BYTES: usize = 16 * 1024;

/// Who is at the other end, read from the kernel (`SO_PEERCRED`).
#[derive(Debug, Clone, Copy)]
pub(crate) struct Peer {
    pub(crate) uid: u32,
    pub(crate) pid: Option<i32>,
}

/// Length of the message whose first bytes are `head`, as it declares it.
/// `None` when the header is not one of a D-Bus message or the sum overflows.
pub(crate) fn declared_len(head: &[u8]) -> Option<usize> {
    let read: fn([u8; 4]) -> u32 = match head.first()? {
        b'l' => u32::from_le_bytes,
        b'B' => u32::from_be_bytes,
        _ => return None,
    };
    let word = |at: usize| -> Option<usize> {
        let bytes: [u8; 4] = head.get(at..at.checked_add(4)?)?.try_into().ok()?;
        usize::try_from(read(bytes)).ok()
    };
    let body = word(4)?;
    let fields = word(12)?;
    // The header fields are padded to 8 bytes before the body starts.
    let header = FIXED_HEADER.checked_add(fields)?.checked_add(7)? & !7;
    header.checked_add(body)
}

/// Splits `stream` into halves that enforce `max_message` bytes per message.
pub(crate) fn capped(stream: UnixStream, peer: Peer, max_message: usize) -> BoxedSplit {
    let (read, write) = stream.into_split();
    let read = Reader {
        raw: Raw { half: read, peer },
        handshake_left: HANDSHAKE_BYTES,
        max_message,
    };
    Split::new(Box::new(read), Box::new(Writer { half: write, peer }))
}

fn credentials(peer: Peer) -> ConnectionCredentials {
    let creds = ConnectionCredentials::default().set_unix_user_id(peer.uid);
    match peer.pid.and_then(|pid| u32::try_from(pid).ok()) {
        Some(pid) => creds.set_process_id(pid),
        None => creds,
    }
}

/// Plain reads; the library's own message assembly on top.
#[derive(Debug)]
struct Raw {
    half: OwnedReadHalf,
    peer: Peer,
}

#[async_trait]
impl ReadHalf for Raw {
    async fn recvmsg(&mut self, buf: &mut [u8]) -> io::Result<(usize, Vec<OwnedFd>)> {
        // A plain read: descriptors a client attaches are closed by the kernel.
        Ok((self.half.read(buf).await?, Vec::new()))
    }

    async fn peer_credentials(&mut self) -> io::Result<ConnectionCredentials> {
        Ok(credentials(self.peer))
    }
}

#[derive(Debug)]
struct Reader {
    raw: Raw,
    handshake_left: usize,
    max_message: usize,
}

#[async_trait]
impl ReadHalf for Reader {
    /// Only the handshake reads through here; messages go through
    /// `receive_message`.
    async fn recvmsg(&mut self, buf: &mut [u8]) -> io::Result<(usize, Vec<OwnedFd>)> {
        let (read, fds) = self.raw.recvmsg(buf).await?;
        self.handshake_left = self
            .handshake_left
            .checked_sub(read)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "handshake too long"))?;
        Ok((read, fds))
    }

    async fn receive_message(
        &mut self,
        seq: u64,
        already_received_bytes: &mut Vec<u8>,
        already_received_fds: &mut Vec<OwnedFd>,
    ) -> zbus::Result<Message> {
        // Read the fixed header alone first, so that the declared length is
        // checked before a buffer of that size exists.
        while already_received_bytes.len() < FIXED_HEADER {
            let mut head = [0u8; FIXED_HEADER];
            let missing = FIXED_HEADER - already_received_bytes.len();
            let room = head.get_mut(..missing).unwrap_or_default();
            let (read, _) = self.raw.recvmsg(room).await?;
            if read == 0 {
                return Err(io::Error::from(io::ErrorKind::UnexpectedEof).into());
            }
            already_received_bytes.extend_from_slice(head.get(..read).unwrap_or_default());
        }
        match declared_len(already_received_bytes) {
            Some(len) if len <= self.max_message => {}
            _ => return Err(zbus::Error::ExcessData),
        }
        self.raw
            .receive_message(seq, already_received_bytes, already_received_fds)
            .await
    }

    async fn peer_credentials(&mut self) -> io::Result<ConnectionCredentials> {
        Ok(credentials(self.raw.peer))
    }
}

#[derive(Debug)]
struct Writer {
    half: OwnedWriteHalf,
    peer: Peer,
}

#[async_trait]
impl WriteHalf for Writer {
    async fn sendmsg(
        &mut self,
        buffer: &[u8],
        _fds: &[std::os::fd::BorrowedFd<'_>],
    ) -> io::Result<usize> {
        self.half.write(buffer).await
    }

    async fn close(&mut self) -> io::Result<()> {
        self.half.shutdown().await
    }

    async fn peer_credentials(&mut self) -> io::Result<ConnectionCredentials> {
        Ok(credentials(self.peer))
    }
}

#[cfg(test)]
mod tests {
    use super::declared_len;

    fn header(endian: u8, body: u32, fields: u32) -> Vec<u8> {
        let word = |value: u32| match endian {
            b'B' => value.to_be_bytes(),
            _ => value.to_le_bytes(),
        };
        let mut head = vec![endian, 1, 0, 1];
        head.extend_from_slice(&word(body));
        head.extend_from_slice(&word(1));
        head.extend_from_slice(&word(fields));
        head
    }

    #[test]
    fn length_is_header_padded_fields_and_body() {
        assert_eq!(declared_len(&header(b'l', 0, 0)), Some(16));
        assert_eq!(declared_len(&header(b'l', 5, 1)), Some(16 + 8 + 5));
        assert_eq!(declared_len(&header(b'l', 5, 8)), Some(16 + 8 + 5));
        assert_eq!(declared_len(&header(b'B', 5, 9)), Some(16 + 16 + 5));
    }

    #[test]
    fn huge_lengths_are_reported_not_wrapped() {
        let len = declared_len(&header(b'l', u32::MAX, u32::MAX));
        assert!(len.is_none_or(|len| len > u32::MAX as usize));
    }

    #[test]
    fn a_header_that_is_short_or_of_another_protocol_has_no_length() {
        assert_eq!(declared_len(&[]), None);
        assert_eq!(declared_len(&header(b'l', 0, 0)[..15]), None);
        assert_eq!(declared_len(&header(b'x', 0, 0)), None);
    }
}
