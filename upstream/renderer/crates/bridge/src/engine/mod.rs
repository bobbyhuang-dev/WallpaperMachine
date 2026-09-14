mod activation;
mod facade;

pub use activation::{ActivationInputs, WallpaperAssignmentExt};
#[cfg(test)]
pub use facade::FakeEngineFacade;
pub use facade::{EngineFacade, RealEngineFacade};
