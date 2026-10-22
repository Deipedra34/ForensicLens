// Intentionally empty. This target is linked as a WASI reactor module (see
// ../../Package.swift): the page calls `_initialize` once and then the
// exported functions in Exports.swift, so no top-level code ever runs.
