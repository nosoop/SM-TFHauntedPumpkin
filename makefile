SPCOMP := spcomp
SPCOMP_FLAGS := -v0

SCRIPTING_DIR := scripting
PLUGINS_DIR := plugins

INPUT_PLUGINS = tf_pumpkin_sf2015.sp

# Build process

TARGET_PLUGINS := $(patsubst %.sp,$(PLUGINS_DIR)/%.smx,$(INPUT_PLUGINS))

$(TARGET_PLUGINS): $(PLUGINS_DIR)/%.smx: $(SCRIPTING_DIR)/%.sp
	@mkdir -p $(@D)
	$(SPCOMP) $(SPCOMP_FLAGS) "$<" -o"$@"

clean:
	@rm -r plugins

.PHONY: clean
