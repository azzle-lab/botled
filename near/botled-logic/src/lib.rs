//! Pure rules for the Botled NEAR registry (no near-sdk). `botled-registry` is the NEAR wrapper.

pub mod crypto;
pub mod oneclick;
pub mod receipt;
pub mod registry;
pub mod ticket;

#[cfg(feature = "derivation")]
pub mod chainsig;

#[cfg(test)]
mod tests;
