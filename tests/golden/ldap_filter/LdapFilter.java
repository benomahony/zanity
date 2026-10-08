class LdapFilter {
    void query(DirContext directory, String base, String filter) throws Exception {
        directory.search(base, filter, null);
    }

    void fixed(DirContext directory, String base, String filter) throws Exception {
        directory.search(base, "(uid=service)", null);
    }

    void localFilter(DirContext directory, String base) throws Exception {
        String filter = "(uid=service)";
        directory.search(base, filter, null);
    }
}
