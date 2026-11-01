// The public half of the key that signs profile updates (scripts/new-profiles-key.mjs writes it). Empty means none yet,
// and then OverPass takes no updates.
enum ProfilesKey {
    nonisolated static let publicKey = ""
}
