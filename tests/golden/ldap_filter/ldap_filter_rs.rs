fn query(ldap: &mut LdapConn, base: &str, filter: &str) {
    ldap.search(base, Scope::Subtree, filter, vec!["uid"]);
}

fn fixed(ldap: &mut LdapConn, base: &str, filter: &str) {
    ldap.search(base, Scope::Subtree, "(uid=service)", vec!["uid"]);
}

fn local_filter(ldap: &mut LdapConn, base: &str) {
    let filter = "(uid=service)";
    ldap.search(base, Scope::Subtree, filter, vec!["uid"]);
}
