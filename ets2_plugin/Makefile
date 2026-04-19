SDK_DIR := ../scs_sdk_1_14
INCLUDES := -I. -I$(SDK_DIR)/include -I$(SDK_DIR)/include/common \
            -I$(SDK_DIR)/include/eurotrucks2 -I$(SDK_DIR)/include/amtrucks

ETS2_PLUGINS := /Volumes/Samsung_T5/SteamLibrary/steamapps/common/Euro Truck Simulator 2/Euro Truck Simulator 2.app/Contents/MacOS/plugins

TARGET := ff_telemetry.so

CXXFLAGS := -arch x86_64 -std=c++17 -O2 -fPIC -Wall -Wno-unused-parameter

$(TARGET): ff_plugin.cpp ets2_ff_shm.h $(SDK_DIR)/include/scssdk.h
	clang++ $(CXXFLAGS) --shared -Wl,-install_name,$@ $(INCLUDES) -o $@ ff_plugin.cpp

.PHONY: install
install: $(TARGET)
	mkdir -p "$(ETS2_PLUGINS)"
	cp $(TARGET) "$(ETS2_PLUGINS)/"
	@echo "Installed: $(ETS2_PLUGINS)/$(TARGET)"

.PHONY: clean
clean:
	rm -f $(TARGET)
