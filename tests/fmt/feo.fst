// Entrada desordenada para 'faset fmt' (tests/fmt): el resultado debe ser feo.expected.
using std;
using std.collections;



union Forma {
  Circulo(double Radio),
     Rect(double Ancho,double Alto),
  Punto;
    public double Area()=>this switch {
        Circulo(var r)=>3.0*r*r,
        Rect(var a,var h)=>a*h,
        Punto=>0,
    };
}

class Programa{
    /* comentario   de bloque   que no se toca */
    static Result<int,string> Leer(string s){
        if(s.Length==0){return Err("vacío");}
        else{
          return Ok(int.Parse(s));
        }
    }

    static Result<long,string> Doble(string s) {
        var r=Leer(s);
        defer println("fin   de Doble");   // el comentario conserva sus   espacios
        return Ok(r? + 1);
    }

    static IEnumerable<int> Pares(int n){
        for(int i=0;i<n;i++){ if(i%2==0) yield return i; }
    }

    static int Suma(int a,int b)=>a+b;

    static void Main(){
        string s=$"total: {Suma(1,2)}   y {"x"}";
        int x=-1;
        int y=x*-2;
        delegate*<int,int,int> f=&Suma;
        println(5|>Suma(1));
        println(s+" "+y+" "+f(1,2));
        foreach(int p in Pares(6)){
            switch(p){
            case 0:
                println("cero");
                break;
            default:
                println(p);
                break;
            }
        }
        string t=Forma.Rect(2,3) match{ Circulo=>"c",_=>"otro" };
        println(t);
        try{
            println(Doble("41").Unwrap());
        }catch(Exception e){
            println(e.Message);
        }finally{ println("fin"); }
    }
}
