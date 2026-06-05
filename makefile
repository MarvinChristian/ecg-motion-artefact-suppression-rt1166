################################################################################
# Convenience project-root targets for MCUXpresso Build Targets.
# The managed CM7 build still uses Debug/makefile; this file lets the IDE call
# small helper targets from the project root.
################################################################################

.PHONY: Build_CM4_Classifier cm4 clean_cm4 Flash_Phase4_Dual

Build_CM4_Classifier cm4:
	$(MAKE) -C Debug Build_CM4_Classifier

clean_cm4:
	$(MAKE) -C Debug clean_cm4

Flash_Phase4_Dual:
	$(MAKE) -C Debug Flash_Phase4_Dual
