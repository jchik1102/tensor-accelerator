# Render a GDS to PNG with KLayout (run inside the OpenLane image):
#   klayout -zz -rd gds=IN.gds -rd lyp=LAYERS.lyp -rd png=OUT.png -r asic/render.py
import pya

view = pya.LayoutView()
view.load_layout(gds, 0)
view.load_layer_props(lyp)
view.max_hier()
# Show only the routing layers (li1, met1..met5 drawing); wells, implants and
# area markers would cover the whole die.
shown = {"67/20", "68/20", "69/20", "70/20", "71/20", "72/20"}
it = view.begin_layers()
while not it.at_end():
    props = it.current()
    src = props.source.split("@")[0].strip()
    props.visible = src in shown
    view.set_layer_properties(it, props)
    it.next()
view.set_config("background-color", "#ffffff")
view.set_config("grid-visible", "false")
view.set_config("text-visible", "false")
view.zoom_fit()
view.save_image(png, 1600, 1600)
print(f"RENDERED {png}")
