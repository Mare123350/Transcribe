// `code` tells the operator screen what to say and whether a retry could help.
//   not_found:   the passage doesn't exist in this translation
//   unavailable: the translation isn't configured, or the provider refused our credentials
//   upstream:    network or provider trouble; worth retrying
export class BibleError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}
