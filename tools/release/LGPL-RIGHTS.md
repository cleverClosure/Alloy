# Your rights in the LGPL components

Status: draft for counsel review (issue 13). Not yet legal text; do not ship as final.

This product includes components licensed under the GNU Lesser General Public
License. They are listed, with their versions and the licence version elected
for each, in `NOTICES.md`. At the time of writing they are Wine and DXMT, both
under LGPL version 2.1.

Nothing in the product's End User Licence Agreement takes away a right the LGPL
gives you in those components. Whatever else the agreement says:

1. **You may modify them.** You may change any LGPL component and use your
   changed version with this product.
2. **You may reverse engineer to debug your changes.** To the extent needed to
   debug modifications you make to an LGPL component, you may reverse engineer
   this product.
3. **Your build will run.** The official runtime is signed and is not altered by
   anything you do. A runtime containing a library you built is your own: it is
   not signed or notarized by us and we do not support it, but the product does
   not refuse to run it because a library was replaced.
4. **The source is published.** The complete corresponding source for every
   LGPL component in a release — our fork, our changes against the upstream
   project, the build configuration, and build instructions — is published
   alongside that release, at the location given in `NOTICES.md`, for as long
   as the release itself is offered.
5. **The instructions are tested.** `REBUILD.md` describes how to rebuild a
   component, sign it yourself, and substitute it. That path is exercised
   against every release before it ships.

If a term of the End User Licence Agreement conflicts with the LGPL as it
applies to these components, the LGPL governs for those components.

## Open points for counsel

- Whether point 4's "for as long as the release is offered" satisfies
  LGPL-2.1 section 6(d), or a three-year written offer under 6(c) is wanted as
  well.
- The wording of point 2 against the reverse-engineering clause the main
  agreement will carry.
- Whether MIT-licensed FEX needs anything here beyond the notice and licence
  text already shipped.
