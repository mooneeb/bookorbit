extension AuthUser {
  func hasPermission(_ permission: Permission) -> Bool {
    isSuperuser || permissions.contains(permission.rawValue)
  }
}
