// Regenerates the test fixtures in this directory.
//
//   clang++ -std=c++17 -O2 \
//       -I"$(brew --prefix opencascade)/include/opencascade" \
//       make_fixtures.cpp -o /tmp/make_fixtures \
//       -L"$(brew --prefix opencascade)/lib" \
//       -lTKernel -lTKMath -lTKG2d -lTKG3d -lTKGeomBase -lTKGeomAlgo \
//       -lTKBRep -lTKTopAlgo -lTKPrim -lTKBO -lTKBool -lTKFillet -lTKMesh \
//       -lTKShHealing -lTKXSBase -lTKLCAF -lTKCAF -lTKXCAF -lTKDE \
//       -lTKDESTEP -lTKDEIGES -lTKDESTL
//   cd tests && /tmp/make_fixtures
//
// The fixtures are committed, so this only needs running when the geometry
// they are meant to cover changes. They are deliberately built from real
// B-rep solids rather than written by hand: a fixture that carries no
// trimmed surfaces would not exercise the tessellation path that the
// previewer actually depends on.
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRep_Builder.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Compound.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Shape.hxx>

#include <TDocStd_Document.hxx>
#include <XCAFDoc_ColorTool.hxx>
#include <XCAFDoc_ColorType.hxx>
#include <XCAFDoc_DocumentTool.hxx>
#include <XCAFDoc_ShapeTool.hxx>

#include <IGESCAFControl_Writer.hxx>
#include <IGESControl_Controller.hxx>
#include <IGESData_GlobalSection.hxx>
#include <IGESData_IGESModel.hxx>
#include <Interface_Static.hxx>
#include <STEPCAFControl_Writer.hxx>
#include <STEPControl_StepModelType.hxx>
#include <StlAPI_Writer.hxx>

#include <Quantity_Color.hxx>
#include <TCollection_HAsciiString.hxx>
#include <TCollection_ExtendedString.hxx>
#include <TDataStd_Name.hxx>
#include <gp_Ax2.hxx>
#include <gp_Dir.hxx>
#include <gp_Pnt.hxx>

#include <cstdio>

namespace {

// A plate with rounded edges and a bore through it. The fillets contribute
// toroidal and spherical faces and the bore a cylindrical one, so a reader
// that only handles planes will visibly fail on this.
TopoDS_Shape makePlate() {
    const TopoDS_Shape box = BRepPrimAPI_MakeBox(40.0, 24.0, 8.0).Shape();

    BRepFilletAPI_MakeFillet fillet(box);
    for (TopExp_Explorer it(box, TopAbs_EDGE); it.More(); it.Next()) {
        fillet.Add(2.0, TopoDS::Edge(it.Current()));
    }
    fillet.Build();
    const TopoDS_Shape rounded = fillet.IsDone() ? fillet.Shape() : box;

    // Drilled from below the plate and run past the top so the cut is clean
    // through, rather than leaving a coincident face at either end.
    const gp_Ax2 axis(gp_Pnt(20.0, 12.0, -1.0), gp_Dir(0.0, 0.0, 1.0));
    const TopoDS_Shape drill = BRepPrimAPI_MakeCylinder(axis, 6.0, 10.0).Shape();

    BRepAlgoAPI_Cut cut(rounded, drill);
    cut.Build();
    return cut.IsDone() ? cut.Shape() : rounded;
}

// A second, separate solid, so the STEP fixture holds an assembly of two
// parts with different colours. That is what exercises the per-face colour
// path and the model colour toggle.
TopoDS_Shape makePin() {
    const gp_Ax2 axis(gp_Pnt(32.0, 12.0, 8.0), gp_Dir(0.0, 0.0, 1.0));
    return BRepPrimAPI_MakeCylinder(axis, 4.0, 18.0).Shape();
}

void addPart(const Handle(XCAFDoc_ShapeTool) & shapes,
             const Handle(XCAFDoc_ColorTool) & colours,
             const TopoDS_Shape &shape,
             const char *name,
             const Quantity_Color &colour) {
    const TDF_Label label = shapes->AddShape(shape, Standard_False);
    TDataStd_Name::Set(label, TCollection_ExtendedString(name));
    colours->SetColor(label, colour, XCAFDoc_ColorGen);
    colours->SetColor(label, colour, XCAFDoc_ColorSurf);
}

int fail(const char *what) {
    std::fprintf(stderr, "failed to write %s\n", what);
    return 1;
}

}  // namespace

int main() {
    const TopoDS_Shape plate = makePlate();
    const TopoDS_Shape pin = makePin();

    const Quantity_Color steel(0.28, 0.45, 0.70, Quantity_TOC_sRGB);
    const Quantity_Color brass(0.85, 0.65, 0.20, Quantity_TOC_sRGB);

    Handle(TDocStd_Document) doc = new TDocStd_Document("MDTV-XCAF");
    const Handle(XCAFDoc_ShapeTool) shapes =
        XCAFDoc_DocumentTool::ShapeTool(doc->Main());
    const Handle(XCAFDoc_ColorTool) colours =
        XCAFDoc_DocumentTool::ColorTool(doc->Main());
    addPart(shapes, colours, plate, "plate", steel);
    addPart(shapes, colours, pin, "pin", brass);

    // Millimetres, and the AP214 flavour that CAD packages most consistently
    // write colours in.
    Interface_Static::SetCVal("write.step.unit", "MM");
    Interface_Static::SetCVal("write.step.schema", "AP214IS");

    STEPCAFControl_Writer step;
    step.SetColorMode(Standard_True);
    step.SetNameMode(Standard_True);
    if (!step.Transfer(doc, STEPControl_AsIs) ||
        step.Write("spike.step") != IFSelect_RetDone) {
        return fail("spike.step");
    }

    IGESControl_Controller::Init();
    Interface_Static::SetIVal("write.iges.brep.mode", 1);  // solids, not wires
    IGESCAFControl_Writer iges;
    if (!iges.Transfer(doc)) {
        return fail("spike.iges");
    }

    // Overwritten deliberately: left alone, the writer stamps the local
    // account name into the IGES header, which has no business in a
    // committed fixture.
    IGESData_GlobalSection header = iges.Model()->GlobalSection();
    header.SetAuthorName(new TCollection_HAsciiString("mac-cad-preview"));
    header.SetCompanyName(new TCollection_HAsciiString("mac-cad-preview"));
    iges.Model()->SetGlobalSection(header);

    if (!iges.Write("spike.iges")) {
        return fail("spike.iges");
    }

    // STL carries no structure, so both solids go in as one compound. It is
    // written as ASCII to keep the fixture reviewable in a diff.
    TopoDS_Compound both;
    BRep_Builder builder;
    builder.MakeCompound(both);
    builder.Add(both, plate);
    builder.Add(both, pin);

    BRepMesh_IncrementalMesh mesher(both, 0.1, Standard_False, 0.5, Standard_True);
    mesher.Perform();

    StlAPI_Writer stl;
    stl.ASCIIMode() = Standard_True;
    if (!stl.Write(both, "spike.stl")) {
        return fail("spike.stl");
    }

    std::printf("wrote spike.step, spike.iges and spike.stl\n");
    return 0;
}
