plugins/tf_pumpkin_sf2015.smx: scripting/tf_pumpkin_sf2015.sp
	"mkdir" -p plugins
	spcomp scripting/tf_pumpkin_sf2015.sp -o plugins/tf_pumpkin_sf2015.smx -i scripting/

clean:
	rm -fr plugins/
