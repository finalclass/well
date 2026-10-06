# Well.Auth — email aliases

## Contract

`user.email` remains the primary address. Additional addresses identify the
same stable user id and do not create users or copy profiles, grants or history.

`email_aliases ~user_id () : string list` returns the normalized additional
addresses in deterministic order.

`replace_email_aliases ~user_id ~emails () : (unit, string) result` replaces
the complete alias set atomically. A missing user, invalid address or ownership
conflict returns Error and changes nothing. Empty input clears the set.
Normalization uses the existing email normalization and validation. Duplicates
and the primary address are omitted. Primary addresses and aliases form one
exclusive namespace, including archived accounts. Concurrent registration,
primary-email change and alias replacement cannot allocate the same address
to different identities. Existing users keep their ids and primary addresses.

`find_user_by_email`, password login and OTP verification accept every address
of that identity and return the same user with its primary email. OAuth consumers
of that lookup inherit alias resolution. Existing archive and admission rules
continue to apply. Failure budgets are shared across an account's addresses.
An OTP remains bound to the requested address and original user; removing or
reassigning an alias cannot transfer a pending code to another identity.
Deletion removes aliases. A primary-email update rejects ownership conflicts
with aliases and removes the new primary address from that user's alias set.

## Verification

Extend the existing auth test with alias lookup, password and OTP admission,
normalization, replacement and removal, archive rejection, shared failure limits,
registration and primary-update conflicts, concurrent ownership writes, and
pending-code invalidation after alias removal/reassignment. Verify migration
retains existing identities and profiles.
