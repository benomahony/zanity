#[test]
fn saves_the_order() {
    let mut repo = MockRepo::new();
    repo.expect_save().times(1).returning(|_| Ok(()));
    repo.expect_delete().never();
    service(&repo).save(order);
}
